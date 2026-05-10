"""Discover, connect to, and tear down iOS device sessions.

This module is the single owner of all `pymobiledevice3` state. The rest of
`locwarpd` should never import `pymobiledevice3` directly; instead it asks
the `DeviceManager` for a connection or a `LocationService` instance.

Phase 1 supports USB only. Phase 4 adds RemotePairing WiFi tunnel support.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from typing import Any, Optional, TYPE_CHECKING

from pymobiledevice3.exceptions import DeviceHasPasscodeSetError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.remote.tunnel_service import (
    CoreDeviceTunnelProxy,
    TunnelProtocol,
    get_rsds,
    start_tunnel_over_remotepairing,
)
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.usbmux import list_devices

from . import errors
from .location_service import (
    DvtLocationService,
    LegacyLocationService,
    LocationService,
)
from .models import DeviceInfo, parse_ios_version
from .wifi_discovery import WiFiDiscovery, WiFiNotReachable

log = logging.getLogger(__name__)

MIN_SUPPORTED_IOS = (16, 0)


import dataclasses


@dataclass(slots=True)
class _Session:
    """All resources we hold for a single connected device. Cleaned up
    in reverse order on disconnect()."""
    udid: str
    ios_version: str
    name: str
    transport: str                   # "usb" | "network"
    usbmux_lockdown: Any             # always present; the entry point
    rsd: Optional[RemoteServiceDiscoveryService] = None
    tunnel_proxy: Optional[CoreDeviceTunnelProxy] = None
    tunnel_ctx: Any = None
    dvt_provider: Optional[DvtProvider] = None
    location: Optional[LocationService] = None
    navigator: Optional[Any] = None       # locwarpd.navigator.Navigator
    walker: Optional[Any] = None          # locwarpd.random_walker.RandomWalker
    joystick: Optional[Any] = None        # locwarpd.joystick.JoystickController
    # Bonjour-only sessions hold a RemotePairingTunnelService instead of
    # a CoreDeviceTunnelProxy; the rest of the lifecycle is the same.
    remote_pairing_service: Any = None
    # iOS 26 over RemotePairing exposes an RSD whose service map has
    # NEITHER `dtservicehub` nor `dt.simulatelocation`, so the WiFi RSD
    # has no path to set a simulated location at all. When that happens
    # we open a SECOND tunnel over the USB cable (CoreDeviceTunnelProxy)
    # and run DVT on top of *that* RSD, while keeping the WiFi RSD
    # around for whatever else it's still good for. These hold the
    # extra resources that need to be torn down at disconnect.
    fallback_rsd: Optional[RemoteServiceDiscoveryService] = None
    fallback_tunnel_proxy: Optional[CoreDeviceTunnelProxy] = None
    fallback_tunnel_ctx: Any = None


class DeviceManager:
    """The full device lifecycle. Thread-unsafe (single asyncio loop).

    All public methods are coroutines. Callers should treat the manager
    as the single authoritative source for "what's connected right now".
    """

    def __init__(self, wifi_discovery: Optional[WiFiDiscovery] = None) -> None:
        self._sessions: dict[str, _Session] = {}
        self._lock = asyncio.Lock()
        self._wifi = wifi_discovery or WiFiDiscovery()
        # Caches of device facts learned from any successful
        # `lockdown.all_values` read in list_devices(). Sticky across
        # the daemon lifetime so that after a USB unplug the GUI
        # keeps showing the real name / iOS version / Dev Mode
        # status, instead of degrading to the "iPhone (Wi-Fi) iOS 0.0
        # · Dev Mode: unknown" placeholder that the WiFi-Bonjour
        # path produces when it has no other source of truth.
        self._device_names: dict[str, str] = {}
        self._device_ios: dict[str, str] = {}
        self._device_dev_mode: dict[str, bool] = {}

    @property
    def wifi(self) -> WiFiDiscovery:
        return self._wifi

    # ------------------------------------------------------------------
    # Discovery
    # ------------------------------------------------------------------

    async def list_devices(self) -> list[DeviceInfo]:
        """Return every iOS device usbmuxd currently sees, USB or network.

        Read-only — does not establish connections, does not mutate state.
        Calling this is cheap; it's safe to call on every UI refresh.
        """
        out: list[DeviceInfo] = []
        try:
            raw = await list_devices()
        except Exception:
            log.exception("usbmux list_devices failed")
            return out

        # Two passes. First, walk the raw list once to record every
        # transport each UDID is reachable on (so the GUI can show
        # "USB + WiFi" badges even though we only build a single
        # DeviceInfo per UDID below). Second, build the DeviceInfo,
        # preferring the USB row when both are present.
        transports_per_udid: dict[str, set[str]] = {}
        for r in raw:
            udid = getattr(r, "serial", None)
            if not udid:
                continue
            t = self._normalise_transport(getattr(r, "connection_type", "USB"))
            transports_per_udid.setdefault(udid, set()).add(t)

        seen: dict[str, DeviceInfo] = {}
        for r in raw:
            udid = getattr(r, "serial", None)
            if not udid:
                continue
            transport = self._normalise_transport(getattr(r, "connection_type", "USB"))

            # If we already have a USB entry for this UDID, prefer USB.
            if udid in seen and seen[udid].transport == "usb":
                continue

            try:
                lockdown = await create_using_usbmux(serial=udid)
                values = lockdown.all_values
                ios = values.get("ProductVersion", "0.0")

                # Developer Mode toggle exists iOS 16+. Best-effort query;
                # an unpaired device may simply refuse to answer.
                dev_mode: Optional[bool] = None
                if parse_ios_version(ios) >= (16, 0):
                    try:
                        dev_mode = await lockdown.get_developer_mode_status()
                    except Exception:
                        dev_mode = None

                friendly_name = values.get("DeviceName", "iPhone")
                # Cache facts for later promotion of WiFi-only sessions /
                # placeholders whose Bonjour-only path lacks them.
                if friendly_name and friendly_name != "iPhone":
                    self._device_names[udid] = friendly_name
                if ios and ios != "0.0":
                    self._device_ios[udid] = ios
                if dev_mode is not None:
                    self._device_dev_mode[udid] = dev_mode

                info = DeviceInfo(
                    udid=udid,
                    name=friendly_name,
                    ios_version=ios,
                    transport=transport,
                    connected=udid in self._sessions,
                    developer_mode=dev_mode,
                    transports=tuple(sorted(transports_per_udid.get(udid, {transport}))),
                )
                seen[udid] = info
            except Exception:
                log.exception("Failed to query device %s", udid)

        # If the device is connected, the session's transport is the
        # ground truth — that's what we're actually pushing simulated
        # locations through. usbmuxd's preference rules will happily
        # report USB even when the user explicitly opened a Wi-Fi
        # session, so don't trust them over the live session.
        for udid, sess in self._sessions.items():
            if udid in seen:
                seen[udid] = dataclasses.replace(
                    seen[udid],
                    transport=sess.transport,
                    connected=True,
                )

        # If we have an active session for a UDID that usbmuxd no
        # longer sees (e.g. the user pulled the USB cable while a
        # WiFi-fallback session was riding on top of it), promote the
        # session's real `name` / `ios_version` into `seen` BEFORE the
        # wifi_paired pass below. Otherwise wifi_paired's "iPhone
        # (Wi-Fi) iOS 0.0" placeholder would silently overwrite a live
        # session's identity, making the device look disconnected
        # even though our location stream is still active.
        for udid, sess in self._sessions.items():
            if udid in seen:
                continue
            seen[udid] = DeviceInfo(
                udid=udid,
                # Prefer the cached friendly name + dev mode from any
                # earlier USB-side lockdown read so the GUI keeps
                # showing "Frankie's iPhone · Dev Mode: ON" instead of
                # degrading to "iPhone · Dev Mode: unknown" the moment
                # the USB cable comes out.
                name=self._device_names.get(udid, sess.name),
                ios_version=sess.ios_version,
                transport=sess.transport,
                connected=True,
                developer_mode=self._device_dev_mode.get(udid),
                transports=(sess.transport,),
            )

        # WiFi pass: enumerate paired UDIDs from the local pairing-record
        # cache. We deliberately don't do a Bonjour browse here — the
        # full mDNS + RemotePairing handshake takes 20+ seconds in the
        # worst case (one connection attempt per IP per UDID) and would
        # block `device.list` for the whole duration. Treat "has a
        # pairing record" as "might be reachable on WiFi"; the actual
        # tunnel setup happens lazily in `connect()` via Bonjour.
        wifi_paired = set(self._wifi.paired_udids)
        for udid in wifi_paired:
            if udid in seen:
                # Add 'network' to the existing entry's transports.
                existing = seen[udid]
                merged = tuple(sorted(set(existing.transports) | {"network"}))
                seen[udid] = dataclasses.replace(existing, transports=merged)
            else:
                # Bonjour-only entry. We use safe defaults but ALSO
                # promote any cached friendly name / dev mode learned
                # from an earlier USB-side lockdown read. Without
                # this, after the user unplugs USB on a previously-
                # connected device, the entry collapses to "iPhone
                # (Wi-Fi) iOS 0.0 · Dev Mode: unknown" — losing the
                # exact information they saw moments ago.
                placeholder = DeviceInfo(
                    udid=udid,
                    name=self._device_names.get(udid, "iPhone (Wi-Fi)"),
                    ios_version=self._device_ios.get(udid, "0.0"),
                    transport="network",
                    connected=udid in self._sessions,
                    developer_mode=self._device_dev_mode.get(udid),
                    transports=("network",),
                )
                seen[udid] = placeholder

        out.extend(seen.values())

        # Surface connected sessions that usbmuxd no longer reports.
        # Originally this fallback existed for WiFi-tunnel mode where the
        # USB cable is unplugged but the network tunnel is still alive,
        # so the device legitimately disappears from usbmuxd. For plain
        # USB sessions, if usbmuxd doesn't see the device, it's truly gone
        # and we'd rather show that honestly than fake a "still connected"
        # row -- so we restrict the fallback to non-USB transports.
        for udid, sess in self._sessions.items():
            if udid in seen:
                continue
            if sess.transport == "usb":
                continue
            out.append(DeviceInfo(
                udid=udid,
                name=sess.name,
                ios_version=sess.ios_version,
                transport=sess.transport,
                connected=True,
            ))

        return out

    @staticmethod
    def _normalise_transport(raw: Any) -> str:
        s = str(raw).lower()
        if s in ("usb", "wired"):
            return "usb"
        if s in ("network", "wifi", "wireless"):
            return "network"
        return s or "usb"

    # ------------------------------------------------------------------
    # Connection
    # ------------------------------------------------------------------

    async def connect(self, udid: str, prefer_wifi: bool = False) -> DeviceInfo:
        """Open a session to `udid`. Idempotent — re-connecting an already
        connected device is a no-op that returns its current `DeviceInfo`.

        ``prefer_wifi`` forces the daemon to take the Network-transport
        entry for this UDID even if a USB one is also available. Useful
        when the user wants to walk around with the iPhone after pairing.
        Falls back to whatever transport usbmuxd does have if the
        preferred one isn't reachable.
        """
        async with self._lock:
            if udid in self._sessions:
                sess = self._sessions[udid]
                return DeviceInfo(
                    udid=udid,
                    name=sess.name,
                    ios_version=sess.ios_version,
                    transport=sess.transport,
                    connected=True,
                )

        # Figure out which transports we can actually reach the device
        # on. usbmuxd handles USB and (sometimes) Network entries; for
        # iOS 17+ paired iPhones on Wi-Fi we also have to consult
        # Bonjour, since usbmuxd often goes silent there.
        usbmux_transports: set[str] = set()
        try:
            for r in await list_devices():
                if getattr(r, "serial", None) == udid:
                    usbmux_transports.add(
                        self._normalise_transport(getattr(r, "connection_type", "USB"))
                    )
        except Exception:
            pass

        # We don't pre-verify WiFi reachability — the actual handshake
        # happens inside `_connect_via_remote_pairing`. Here we only
        # check whether we have a pairing record for the UDID, which
        # is the prerequisite for any WiFi attempt.
        wifi_paired = udid in self._wifi.paired_udids

        # Order matters here. Two distinct WiFi channels exist on iOS
        # 17+, and they are NOT interchangeable for our purposes:
        #
        # 1. **Network-via-usbmuxd** (the `_apple-mobdev2._tcp` Bonjour
        #    service that Finder's "Show this iPhone when on Wi-Fi"
        #    enables). Lockdown over this gives us
        #    `CoreDeviceTunnelProxy.create()` access — the same flow
        #    the USB path uses — and the resulting RSD has the FULL
        #    developer-service map including `dtservicehub`. Location
        #    simulation works.
        #
        # 2. **RemotePairing** (`_remotepairing._tcp`, what Xcode uses
        #    for wireless debug). On iOS 26 the RSD we get out of this
        #    has a deliberately stripped service map — no
        #    dtservicehub, no dt.simulatelocation. Location simulation
        #    cannot ride this tunnel alone; we'd need a second tunnel
        #    elsewhere as a fallback (which forces USB back into the
        #    picture, defeating the whole point of WiFi mode).
        #
        # Therefore: prefer Network-via-usbmuxd whenever it's
        # available, and only fall back to RemotePairing when the
        # user hasn't enabled "WiFi sync" in Finder. We document this
        # in the GUI so users know the one-time setup that unlocks
        # truly-untethered operation.
        if prefer_wifi and "network" in usbmux_transports:
            transport, bonjour_path = "network", False
        elif prefer_wifi and wifi_paired:
            transport, bonjour_path = "network", True
        elif "usb" in usbmux_transports:
            transport, bonjour_path = "usb", False
        elif "network" in usbmux_transports:
            transport, bonjour_path = "network", False
        elif wifi_paired:
            transport, bonjour_path = "network", True
        else:
            transport, bonjour_path = "usb", False

        if bonjour_path:
            session = await self._connect_via_remote_pairing(udid, transport)
        else:
            connection_type: Optional[str] = (
                "Network" if transport == "network"
                else ("USB" if transport == "usb" else None)
            )
            try:
                if connection_type is not None:
                    lockdown = await create_using_usbmux(
                        serial=udid, connection_type=connection_type
                    )
                else:
                    lockdown = await create_using_usbmux(serial=udid)
            except Exception as exc:
                log.exception("Cannot open lockdown for %s (transport=%s)", udid, transport)
                raise errors.device_not_found(udid) from exc

            ios = lockdown.all_values.get("ProductVersion", "0.0")
            name = lockdown.all_values.get("DeviceName", "iPhone")
            ver = parse_ios_version(ios)

            if ver < MIN_SUPPORTED_IOS:
                raise errors.unsupported_ios(
                    ios, ".".join(map(str, MIN_SUPPORTED_IOS))
                )

            if ver >= (17, 0):
                session = await self._connect_via_tunnel(
                    udid, lockdown, ios, name, transport
                )
            else:
                session = _Session(
                    udid=udid,
                    ios_version=ios,
                    name=name,
                    transport=transport,
                    usbmux_lockdown=lockdown,
                )

        async with self._lock:
            self._sessions[udid] = session

        log.info(
            "Connected %s (iOS %s) via %s",
            udid, session.ios_version, session.transport,
        )
        return DeviceInfo(
            udid=udid,
            name=session.name,
            ios_version=session.ios_version,
            transport=session.transport,
            connected=True,
        )

    async def _connect_via_remote_pairing(
        self, udid: str, transport: str
    ) -> _Session:
        """Connect to a paired iPhone over Bonjour-discovered WiFi.

        Uses pymobiledevice3's high-level `get_rsds(udid=...)` helper
        which:
          1. Bonjour-browses for `_remotepairing._tcp` advertisements.
          2. Establishes the right tunnel for the iOS version
             (TCP for iOS 18.2+, QUIC otherwise) — same defaults the
             pymobiledevice3 CLI uses.
          3. Sets up the kernel route through the new utun interface
             so DVT service ports inside the tunnel are reachable.
          4. Returns a ready-to-use RSD.

        Going through this helper instead of hand-rolling
        `get_remote_pairing_tunnel_services` + `start_tunnel_over_
        remotepairing` is what got Teleport to actually fire on iOS
        26 — the manual flow set up the tunnel but left the
        DVT-port routing in a state where TCP connections to those
        service ports timed out.
        """
        try:
            rsds = await get_rsds(bonjour_timeout=2.0, udid=udid)
        except Exception as exc:
            log.exception("Bonjour RSD setup failed for %s", udid)
            raise errors.tunnel_failed(udid, str(exc)) from exc

        if not rsds:
            raise errors.tunnel_failed(
                udid, "no RemotePairing services answered Bonjour"
            )

        # Pick the first RSD (typically the IPv4 LAN address of the
        # iPhone) and close the rest so they don't keep tunnels alive.
        rsd = rsds[0]
        for extra in rsds[1:]:
            try:
                await extra.close()
            except Exception:
                pass

        # Pull what we can about the device for the GUI. RSD exposes
        # several variants of the version string depending on iOS
        # release; check them in order.
        ios_version = "0.0"
        device_name = "iPhone"
        for attr in ("product_version", "os_version"):
            v = getattr(rsd, attr, None)
            if v:
                ios_version = str(v)
                break
        for attr in ("device_name", "name"):
            v = getattr(rsd, attr, None)
            if v:
                device_name = str(v)
                break

        # RemotePairing's RSD usually doesn't surface the user-set
        # DeviceName, so `device_name` ends up as the generic "iPhone"
        # placeholder. If we've ever seen this UDID over usbmuxd
        # (lockdown.all_values["DeviceName"] cached it for us), promote
        # the friendly name into the session so the GUI shows
        # "Frankie's iPhone" instead of degrading to "iPhone" the
        # moment the user unplugs USB.
        if device_name in ("iPhone", "") and udid in self._device_names:
            device_name = self._device_names[udid]

        return _Session(
            udid=udid,
            ios_version=ios_version,
            name=device_name,
            transport=transport,
            usbmux_lockdown=None,
            rsd=rsd,
            tunnel_proxy=None,
            tunnel_ctx=None,                      # owned by RSD now
            remote_pairing_service=None,          # owned by RSD now
        )

    async def _connect_via_tunnel(
        self, udid: str, lockdown, ios: str, name: str, transport: str
    ) -> _Session:
        """iOS 17+ requires a CoreDeviceTunnelProxy + RSD over TCP."""
        try:
            proxy = await CoreDeviceTunnelProxy.create(lockdown)
            tunnel_ctx = proxy.start_tcp_tunnel()
            tunnel_result = await tunnel_ctx.__aenter__()

            rsd = RemoteServiceDiscoveryService((tunnel_result.address, tunnel_result.port))
            await rsd.connect()

            return _Session(
                udid=udid,
                ios_version=ios,
                name=name,
                transport=transport,
                usbmux_lockdown=lockdown,
                rsd=rsd,
                tunnel_proxy=proxy,
                tunnel_ctx=tunnel_ctx,
            )
        except Exception as exc:
            log.exception("Tunnel setup failed for %s", udid)
            # Best-effort cleanup of partial state.
            try:
                if "tunnel_ctx" in locals():
                    await tunnel_ctx.__aexit__(None, None, None)
            except Exception:
                pass
            raise errors.tunnel_failed(udid, str(exc)) from exc

    async def disconnect(self, udid: str, *, clear_simulation: bool = True) -> bool:
        """Close the session for `udid`. Returns True if a session was
        found and torn down, False if the UDID was not connected (no-op).

        ``clear_simulation`` controls whether the iPhone's simulated GPS
        is reset back to its real value as part of the teardown:

        * **True** (default) — the user is explicitly letting go of the
          device (Disconnect button, USB unplug, Restore + Disconnect
          flow). Clearing makes sense: don't leave the iPhone stranded
          at a fake location.
        * **False** — the daemon is shutting down for reasons unrelated
          to the user's intent (Mac sleep, power off, app quit, SIGTERM
          on launcher exit). We stop the navigator so the iPhone stops
          *moving*, but leave the simulated location in place so the
          phone freezes where it was, rather than snapping back to real
          GPS without warning.
        """
        async with self._lock:
            sess = self._sessions.pop(udid, None)
        if sess is None:
            return False
        await self._teardown_session(sess, clear_simulation=clear_simulation)
        return True

    async def disconnect_all(self, *, clear_simulations: bool = False) -> None:
        """Tear down every session. Default is **shutdown semantics**:
        stop navigators, leave simulations in place. Pass
        ``clear_simulations=True`` for an explicit "log out everywhere"
        flow."""
        async with self._lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for sess in sessions:
            await self._teardown_session(sess, clear_simulation=clear_simulations)

    async def _teardown_session(self, sess: "_Session", *, clear_simulation: bool) -> None:
        """The actual cleanup work. Split out so disconnect() and
        disconnect_all() can share it without each duplicating the
        navigator-stop / RSD-close / tunnel-close ordering."""
        # Stop any in-flight movement first so the loops don't push more
        # positions onto a tearing-down location service. Stopping these
        # does NOT clear the simulation — they just halt the ticker,
        # freezing the iPhone at whatever it last received.
        for runner_attr in ("navigator", "walker", "joystick"):
            runner = getattr(sess, runner_attr, None)
            if runner is not None:
                try:
                    await runner.stop()
                except Exception:
                    log.exception("%s.stop during teardown failed for %s",
                                  runner_attr, sess.udid)

        if clear_simulation and sess.location is not None:
            try:
                await sess.location.clear()
            except Exception:
                log.exception("clear() during teardown failed for %s", sess.udid)

        # Close in reverse order of construction. DVT first (it
        # references whichever RSD it was bound to), then both RSDs,
        # then both tunnel contexts. Fallback resources may be unset;
        # the helper below tolerates that.
        for closer, label in (
            (lambda: sess.dvt_provider and sess.dvt_provider.__aexit__(None, None, None), "dvt"),
            (lambda: sess.fallback_rsd and sess.fallback_rsd.close(),                     "fallback-rsd"),
            (lambda: sess.rsd and sess.rsd.close(),                                       "rsd"),
            (lambda: sess.fallback_tunnel_ctx and sess.fallback_tunnel_ctx.__aexit__(None, None, None), "fallback-tunnel-ctx"),
            (lambda: sess.tunnel_ctx and sess.tunnel_ctx.__aexit__(None, None, None),     "tunnel-ctx"),
        ):
            try:
                aw = closer()
                if aw is not None:
                    await aw
            except Exception:
                log.exception("close %s failed for %s", label, sess.udid)

        for proxy, label in (
            (sess.fallback_tunnel_proxy, "fallback-tunnel-proxy"),
            (sess.tunnel_proxy, "tunnel-proxy"),
        ):
            if proxy is None:
                continue
            # Newer pymobiledevice3 versions made `close` a coroutine.
            # We accept either signature so an upgrade or downgrade of
            # the dependency doesn't trigger "coroutine was never
            # awaited" warnings (or, worse, fail to release the tunnel).
            try:
                result = proxy.close()
                if asyncio.iscoroutine(result):
                    await result
            except Exception:
                log.exception("close %s failed for %s", label, sess.udid)

        # Bonjour-path sessions own the RemotePairingTunnelService
        # instead of (or alongside) the CoreDeviceTunnelProxy.
        if sess.remote_pairing_service is not None:
            try:
                await sess.remote_pairing_service.close()
            except Exception:
                log.exception("close remote-pairing-service failed for %s", sess.udid)

        log.info(
            "Disconnected %s (simulation %s)",
            sess.udid,
            "cleared" if clear_simulation else "preserved",
        )

    async def handle_usbmux_detached(self, udid: str | None) -> list[str]:
        """Drop any session whose USB transport just disappeared.

        We tear down a session when EITHER:

        * Its primary transport is USB (`sess.transport == "usb"`), OR
        * It's a WiFi session that was secretly riding a USB-DVT
          fallback tunnel (`sess.fallback_tunnel_proxy is not None`).

        The second case is the killer: on iOS 26 the user's WiFi
        Connect goes through RemotePairing, gets a service-map-stripped
        RSD, and we silently open a SECOND tunnel over the USB cable
        for DVT. From the user's perspective they're "connected via
        WiFi", but the location pipeline is actually riding USB. When
        the cable comes out, the WiFi tunnel keeps reporting alive,
        but every Teleport will hang on a dead TCP socket. Far better
        to disconnect cleanly and have the GUI honestly say "device
        gone" than to leave a session that lies about being usable.

        Returns the list of UDIDs we actually disconnected, so the
        caller can broadcast a precise event to the GUI.
        """
        def _depends_on_usb(s: _Session) -> bool:
            if s.transport == "usb":
                return True
            # USB-DVT fallback session — see docstring.
            if s.fallback_tunnel_proxy is not None:
                return True
            # Even without our explicit fallback, an `usbmux_lockdown`
            # was minted via usbmuxd which means USB at the time. If
            # the active LocationService is anchored on it, USB unplug
            # ends the session.
            if s.usbmux_lockdown is not None and s.location is not None:
                return True
            return False

        if udid is not None:
            sess = self._sessions.get(udid)
            if sess is not None and _depends_on_usb(sess):
                await self.disconnect(udid)
                return [udid]
            return []

        # No UDID in the event (older usbmuxd protocol). Drop every
        # USB-dependent session as a safe overestimate -- pure WiFi
        # sessions with no USB-fallback survive.
        dropped: list[str] = []
        for udid_, sess in list(self._sessions.items()):
            if _depends_on_usb(sess):
                await self.disconnect(udid_)
                dropped.append(udid_)
        return dropped

    # ------------------------------------------------------------------
    # Developer Mode (AMFI)
    # ------------------------------------------------------------------

    async def reveal_developer_mode(self, udid: str) -> dict[str, Any]:
        """Tell the iPhone to surface the Developer Mode toggle in Settings.

        This does NOT enable Developer Mode by itself — the user still has
        to walk to Settings → Privacy & Security → Developer Mode, flip
        the switch, restart the device, and confirm "Turn On" after the
        passcode prompt. We intentionally take the safer "reveal" path
        rather than the direct "enable" call, because:

        * `enable_developer_mode()` rejects devices that have a passcode
          set, which is most real users.
        * It triggers an automatic restart sequence that's hostile to the
          user if they didn't expect it.

        Returns a small dict the UI can use to drive the next-step banner.
        """
        try:
            lockdown = await create_using_usbmux(serial=udid)
        except Exception as exc:
            raise errors.device_not_found(udid) from exc

        amfi = AmfiService(lockdown)
        try:
            await amfi.reveal_developer_mode_option_in_ui()
        except DeviceHasPasscodeSetError as exc:
            # Reveal *should* work even with a passcode, but pymobiledevice3
            # may surface this for some firmware versions. Surface a clear
            # message so the UI can show actionable instructions.
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message="Device has a passcode set; remove it before continuing.",
            ) from exc
        except Exception as exc:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message=f"Failed to reveal Developer Mode: {exc}",
            ) from exc

        log.info("Revealed Developer Mode toggle on %s", udid)
        return {
            "ok": True,
            "udid": udid,
            "next_steps": [
                "Open Settings → Privacy & Security → Developer Mode on the iPhone.",
                "Turn the switch ON. The iPhone will ask to restart.",
                "After the restart, unlock and tap Turn On at the prompt.",
                "Re-plug USB and click Connect again.",
            ],
        }

    # ------------------------------------------------------------------
    # Location service accessor
    # ------------------------------------------------------------------

    async def session_for(self, udid: str) -> "_Session":
        """Return the live session for `udid` or raise device_not_connected."""
        async with self._lock:
            sess = self._sessions.get(udid)
        if sess is None:
            raise errors.device_not_connected(udid)
        return sess

    async def set_navigator(self, udid: str, navigator: Any) -> None:
        """Attach a Navigator to the device session. Replaces any existing
        navigator (caller is responsible for stopping the old one first)."""
        async with self._lock:
            sess = self._sessions.get(udid)
        if sess is None:
            raise errors.device_not_connected(udid)
        sess.navigator = navigator

    async def set_walker(self, udid: str, walker: Any) -> None:
        async with self._lock:
            sess = self._sessions.get(udid)
        if sess is None:
            raise errors.device_not_connected(udid)
        sess.walker = walker

    async def set_joystick(self, udid: str, joystick: Any) -> None:
        async with self._lock:
            sess = self._sessions.get(udid)
        if sess is None:
            raise errors.device_not_connected(udid)
        sess.joystick = joystick

    async def location_for(self, udid: str) -> LocationService:
        """Return (and lazily create) the right `LocationService` for `udid`.

        Raises a domain `RpcError` if the device isn't connected.
        """
        async with self._lock:
            sess = self._sessions.get(udid)
        if sess is None:
            raise errors.device_not_connected(udid)

        if sess.location is not None:
            return sess.location

        # When the session was opened over Bonjour/RemotePairing the
        # `usbmux_lockdown` is None and the version string can be a
        # placeholder ("0.0"). DVT only cares about the RSD, and any
        # device that answered `_remotepairing._tcp` is iOS 17+ by
        # definition — older firmwares don't advertise it. So if we
        # have an RSD, take the DVT path regardless of the parsed
        # version.
        ver = parse_ios_version(sess.ios_version)
        log.info("location_for[v0.2.3]: udid=%s ios=%s rsd=%s usbmux=%s",
                 sess.udid, sess.ios_version,
                 sess.rsd is not None, sess.usbmux_lockdown is not None)
        if sess.rsd is not None or ver >= (17, 0):
            assert sess.rsd is not None, "iOS 17+ session missing RSD"
            try:
                log.info("location_for[v0.2.3]: trying DvtProvider on primary RSD...")
                dvt = DvtProvider(sess.rsd)
                await dvt.__aenter__()
                sess.dvt_provider = dvt
                sess.location = DvtLocationService(dvt, sess.rsd)
                log.info("location_for[v0.2.3]: DVT path OK on primary RSD")
            except Exception as exc:
                # iOS 26 over RemotePairing (Bonjour/WiFi) exposes an
                # RSD whose service map has NEITHER
                # `com.apple.instruments.dtservicehub` NOR
                # `com.apple.dt.simulatelocation`. The WiFi tunnel is
                # therefore a dead end for location simulation by
                # itself.
                #
                # The USB-side CoreDeviceTunnelProxy, however, gives
                # us an RSD that DOES expose dtservicehub — that's
                # exactly the path the USB-Connect flow uses, and
                # we know it works (USB Teleport succeeds even on
                # iOS 26.4.2). So if usbmuxd can still see the device
                # (USB cable plugged in), open a SECOND tunnel over
                # USB and use DVT there. This keeps the user's WiFi
                # connection alive for presence purposes while making
                # location ops actually work.
                log.warning(
                    "DVT failed on primary RSD for %s (%s: %s); "
                    "trying USB-tunnel DVT fallback",
                    sess.udid, type(exc).__name__, exc,
                )
                usb_lockdown = sess.usbmux_lockdown
                if usb_lockdown is None:
                    try:
                        usb_lockdown = await create_using_usbmux(serial=sess.udid)
                        sess.usbmux_lockdown = usb_lockdown
                        log.info(
                            "location_for[v0.2.3]: opened usbmux "
                            "lockdown for %s for DVT fallback",
                            sess.udid,
                        )
                    except Exception as lex:
                        log.error(
                            "USB lockdown unavailable for %s (%s); "
                            "WiFi-only iOS 17+ has no working location "
                            "path on iOS 26",
                            sess.udid, lex,
                        )
                        raise errors.RpcError(
                            code=errors.PYMD3_ERROR,
                            message=(
                                "iOS 17+ over WiFi alone can't reach the "
                                "location service on this firmware. Plug "
                                "in the USB cable and try again — the "
                                "daemon will use USB DVT under the hood "
                                "while keeping the WiFi badge."
                            ),
                        ) from exc

                # Build a fresh USB-RSD via CoreDeviceTunnelProxy.
                # Identical flow to `_connect_via_tunnel`, but stored
                # in `fallback_*` slots so the primary WiFi RSD stays
                # untouched for teardown bookkeeping.
                tunnel_ctx = None
                try:
                    log.info(
                        "location_for[v0.2.3]: opening USB tunnel for %s",
                        sess.udid,
                    )
                    proxy = await CoreDeviceTunnelProxy.create(usb_lockdown)
                    tunnel_ctx = proxy.start_tcp_tunnel()
                    tunnel_result = await tunnel_ctx.__aenter__()
                    usb_rsd = RemoteServiceDiscoveryService(
                        (tunnel_result.address, tunnel_result.port)
                    )
                    await usb_rsd.connect()

                    dvt = DvtProvider(usb_rsd)
                    await dvt.__aenter__()

                    sess.fallback_tunnel_proxy = proxy
                    sess.fallback_tunnel_ctx = tunnel_ctx
                    sess.fallback_rsd = usb_rsd
                    sess.dvt_provider = dvt
                    sess.location = DvtLocationService(dvt, usb_rsd)
                    log.info(
                        "location_for[v0.2.3]: USB-DVT fallback OK for %s",
                        sess.udid,
                    )
                except Exception as fex:
                    log.exception(
                        "USB-DVT fallback also failed for %s", sess.udid
                    )
                    # Best-effort cleanup of partial tunnel state.
                    if tunnel_ctx is not None:
                        try:
                            await tunnel_ctx.__aexit__(None, None, None)
                        except Exception:
                            pass
                    raise errors.RpcError(
                        code=errors.PYMD3_ERROR,
                        message=(
                            f"DVT not available on either WiFi RSD or "
                            f"USB tunnel for {sess.udid}: {fex}"
                        ),
                    ) from fex
        else:
            sess.location = LegacyLocationService(sess.usbmux_lockdown)

        return sess.location
