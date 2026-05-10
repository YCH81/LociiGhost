"""mDNS-based WiFi device discovery.

iOS 17+ stops advertising paired iPhones via usbmuxd's Network transport
in many setups. The new path Apple uses for the developer tunnel is
Bonjour: the iPhone broadcasts a `_remotepairing._tcp` service when it's
on a network reachable from a paired Mac. pymobiledevice3 has all the
plumbing for talking to that service; we just need to feed our device
manager.

This module wraps `get_remote_pairing_tunnel_services` in a small TTL
cache so repeated `device.list` calls don't re-do a 3-second Bonjour
browse every time. Connections opened during discovery are closed
immediately — we cache only the lightweight `(udid, hostname, port)`
tuples and create a fresh tunnel service on demand at connect time.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass

from pymobiledevice3.remote.tunnel_service import (
    create_core_device_tunnel_service_using_remotepairing,
    get_remote_pairing_tunnel_services,
    iter_remote_paired_identifiers,
)

log = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class WiFiTarget:
    """Lightweight info about a paired iPhone reachable over Bonjour."""
    udid: str
    hostname: str
    port: int


class WiFiDiscovery:
    """Lightweight + on-demand WiFi tunnel access for paired iPhones.

    Two layers, intentionally separated by speed:

    * `paired_udids` — instant, reads the local pairing-record cache
      under `~/.pymobiledevice3`. Used by `device.list` so the
      sidebar can paint a `WiFi` badge for every paired UDID without
      blocking on the network.

    * `open_tunnel_service(udid)` — slow, does the full Bonjour browse
      + RemotePairing handshake. Called only when the user actually
      clicks "Connect via WiFi", so the cost (a few seconds of
      sequential connection attempts) is only paid for the device
      they care about.

    The earlier "discover everything ahead of time" approach
    (`get_remote_pairing_tunnel_services` for every paired device)
    blocked the RPC loop for 20+ seconds and made `daemon.info`
    appear hung — pymobiledevice3 walks every (UDID × IP × interface)
    tuple sequentially and link-local IPv6 timeouts are unavoidable.
    """

    def __init__(self) -> None:
        self._lock = asyncio.Lock()

    @property
    def paired_udids(self) -> list[str]:
        """All UDIDs that have a pairing record on disk. Reading these
        is a synchronous filesystem walk; no network I/O."""
        try:
            return list(iter_remote_paired_identifiers())
        except Exception:
            log.exception("Failed to enumerate paired identifiers")
            return []

    async def discover(self, *, force: bool = False) -> dict[str, list[WiFiTarget]]:
        """Compatibility shim. Returns one placeholder target per paired
        UDID without doing a Bonjour browse, so callers that care about
        the "set of UDIDs available on WiFi" still work, but
        `device.list` doesn't pay the multi-second handshake cost."""
        del force                # cache is stateless now
        return {udid: [] for udid in self.paired_udids}

    def targets_for(self, udid: str) -> list[WiFiTarget]:
        # We don't pre-resolve hostnames any more; `open_tunnel_service`
        # rediscovers them on demand. Keeping the method around for
        # callers that just want a yes/no answer to "could this go via
        # WiFi": treat any paired UDID as "potentially reachable".
        return [WiFiTarget(udid=udid, hostname="", port=0)] if udid in self.paired_udids else []

    async def open_tunnel_service(self, udid: str):
        """Slow path. Browse Bonjour and try each address until one
        accepts the RemotePairing handshake for `udid`. Runs only when
        the user explicitly Connects over WiFi."""
        async with self._lock:
            try:
                services = await get_remote_pairing_tunnel_services(
                    bonjour_timeout=2.0, udid=udid
                )
            except Exception as exc:
                raise WiFiNotReachable(udid, exc) from exc

            if not services:
                raise WiFiNotReachable(udid)

            chosen = services[0]
            # Close every other live connection get_remote_... opened
            # so we don't leak file descriptors. Same-IP-different-route
            # duplicates are common in this list.
            for svc in services[1:]:
                try:
                    await svc.close()
                except Exception:
                    pass
            return chosen


class WiFiNotReachable(RuntimeError):
    def __init__(self, udid: str, cause: Exception | None = None) -> None:
        super().__init__(f"No reachable WiFi target for {udid}: {cause}" if cause
                         else f"No reachable WiFi target for {udid}")
        self.udid = udid
        self.cause = cause
