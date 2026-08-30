"""Inject simulated GPS coordinates into a connected iPhone.

Two implementations exist because iOS draws the line at 17.0:

* **DvtLocationService** (iOS 17+) talks to the DVT `LocationSimulation`
  instrument through an established RSD tunnel. This is the same channel
  Xcode uses internally.
* **LegacyLocationService** (iOS 16.x) uses the older
  `com.apple.dt.simulatelocation` lockdown service over plain usbmux.

Both expose the same async interface (`set` / `clear`), so the calling
code never has to know which one it's holding.

v1.15.2 keepalive (Phase 1):
The base class now spawns a background asyncio task on
`start_keepalive()` that periodically re-pushes the last successful
coordinate when no real `set()` has happened recently. This keeps the
DVT runloop on the iPhone side from being suspended by iOS power
management — which used to manifest as "InvalidService" errors after a
few minutes of idle or during dwell-mode pauses. The keepalive ticks
are emitted at `DEBUG` log level so the per-3s heartbeat doesn't
drown the actual user-issued sets in the INFO stream.
"""

from __future__ import annotations

import asyncio
import inspect
import logging
import time
from abc import ABC, abstractmethod
from typing import Optional

from pymobiledevice3.exceptions import (
    ConnectionTerminatedError,
    PyMobileDevice3Exception,
)
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.simulate_location import DtSimulateLocation

log = logging.getLogger(__name__)


# Network errors that often mean "the channel died, reconnect and try again".
#
# v1.15.2 audit (W1): `PyMobileDevice3Exception` is the base of
# InvalidServiceError / StartServiceError / MuxException /
# ConnectionFailedError / DeviceNotFoundError. None of those derive
# from OSError, so before this line the single most common symptom
# this module exists to recover from -- "InvalidService after a few
# minutes idle" -- fell straight through the retry ladder and was
# swallowed by the keepalive loop at DEBUG level. Catching the base
# class is deliberate: every pymobiledevice3-level failure here means
# "the pipe to the phone is unusable", which is exactly what
# `_reconnect()` fixes.
_RECOVERABLE = (
    ConnectionTerminatedError,
    PyMobileDevice3Exception,
    OSError,
    EOFError,
    BrokenPipeError,
    ConnectionResetError,
    asyncio.TimeoutError,
)


class LocationService(ABC):
    # Last (lat, lng) successfully pushed to the iPhone. Used by
    # phone-side `/api/phone/navigate` (and any future caller that
    # needs an "origin" for routing) so we don't have to round-trip
    # through the iPhone to ask "where did we last put you?". Set by
    # subclasses inside their `set()` implementation; cleared on
    # `clear()`. Subclass `__init__` should default this to None.
    last_lat_lng: Optional[tuple[float, float]] = None

    # ── Keepalive (v1.15.2 Phase 1) ───────────────────────────────────
    # Time of the most recent successful `set()`. The keepalive loop
    # consults this to skip ticks while the navigator / joystick /
    # random walker is already pushing positions at high cadence — we
    # only re-push when there's been a gap long enough that the DVT
    # pipe might be cooling off.
    #
    # 3 s tick + 2.5 s guard means: if the last user-issued set was
    # within 2.5 s, skip; otherwise re-push the same coord. Navigator
    # ticks at 1 s, joystick at 0.5 s, random walker at 1 s — all
    # comfortably below the guard, so keepalive only fires during
    # idle, pause, or dwell-at-stop windows.
    KEEPALIVE_INTERVAL_S: float = 3.0
    KEEPALIVE_GUARD_S: float = 2.5

    # Every Nth keepalive re-push gets logged at INFO instead of DEBUG
    # so the default-INFO log still gives proof the heartbeat is alive
    # without drowning real movement. 10 * 3s = ~30s INFO cadence.
    KEEPALIVE_INFO_EVERY: int = 10

    _last_set_at: float = 0.0
    _keepalive_task: Optional[asyncio.Task] = None
    _keepalive_tick_count: int = 0

    # ── Liveness signal (v1.15.2 audit W5) ────────────────────────────
    # The TCP probe in DeviceManager only proves the iPhone answers on
    # its RemotePairing port. On iOS 26 the WiFi session commonly rides
    # a USB DVT fallback, so the phone can be perfectly reachable on
    # the LAN while the channel we actually push locations down is
    # dead. The keepalive is the only thing that exercises that channel
    # during idle, so its success rate — not a socket connect — is the
    # honest liveness signal. DeviceManager's health loop reads these.
    KEEPALIVE_DEGRADED_AFTER: int = 3     # ~9 s of silence
    KEEPALIVE_DEAD_AFTER: int = 10        # ~30 s -> tear the session down
    consecutive_keepalive_failures: int = 0
    last_keepalive_ok_at: float = 0.0

    # Set by subclasses in __init__. Declared here so the base-class
    # keepalive loop can check it without knowing the subclass.
    _call_lock: Optional[asyncio.Lock] = None

    @abstractmethod
    async def set(self, lat: float, lng: float, *,
                  retries: Optional[int] = None) -> None: ...

    @abstractmethod
    async def clear(self) -> None: ...

    def start_keepalive(self) -> None:
        """Begin re-pushing `last_lat_lng` every KEEPALIVE_INTERVAL_S
        whenever no actual `set()` happened recently. Idempotent: a
        second call while a task is alive is a no-op."""
        if self._keepalive_task is not None and not self._keepalive_task.done():
            return
        self._keepalive_task = asyncio.create_task(
            self._keepalive_loop(),
            name="location-keepalive",
        )

    async def stop_keepalive(self) -> None:
        """Cancel the keepalive task and await its exit. Safe to call
        repeatedly. DeviceManager.disconnect must call this BEFORE
        tearing down the underlying DVT provider so an in-flight
        keepalive tick doesn't race against shutdown."""
        task = self._keepalive_task
        self._keepalive_task = None
        if task is None or task.done():
            return
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        except Exception:
            log.debug("location-keepalive exited with exception", exc_info=True)

    def _note_keepalive(self, ok: bool) -> None:
        """Record the outcome of one heartbeat tick."""
        if ok:
            if self.consecutive_keepalive_failures:
                log.info("location keepalive recovered after %d failure(s)",
                         self.consecutive_keepalive_failures)
            self.consecutive_keepalive_failures = 0
            self.last_keepalive_ok_at = time.monotonic()
            return
        self.consecutive_keepalive_failures += 1
        n = self.consecutive_keepalive_failures
        # First failure is a warning; after that only every Nth, so a
        # long outage doesn't bury everything else in the log.
        if n == 1 or n % self.KEEPALIVE_DEGRADED_AFTER == 0:
            log.warning(
                "location keepalive failing (%d consecutive; "
                "degraded at %d, session dropped at %d)",
                n, self.KEEPALIVE_DEGRADED_AFTER, self.KEEPALIVE_DEAD_AFTER,
            )
        else:
            log.debug("location keepalive tick failed (%d consecutive)",
                      n, exc_info=True)

    async def _keepalive_loop(self) -> None:
        while True:
            try:
                await asyncio.sleep(self.KEEPALIVE_INTERVAL_S)
            except asyncio.CancelledError:
                return
            try:
                # v1.15.2 audit (W3): never queue behind a real set().
                # The guard and the coordinate below are read outside
                # the call lock, so if we blocked on it a mover could
                # advance several ticks while we waited and we would
                # then push a stale coordinate — visibly yanking the
                # iPhone backwards. A held lock already means the
                # channel is being exercised, which is the entire
                # point of the heartbeat, so skipping is also correct.
                lock = self._call_lock
                if lock is not None and lock.locked():
                    continue
                if self.last_lat_lng is None:
                    # Nothing to re-push yet — user hasn't issued a
                    # first set() since this session was created. We
                    # COULD push a fallback "wake" coord here, but
                    # that would visibly teleport the iPhone the
                    # moment it connects, which is worse than the
                    # alternative (first real teleport pays the
                    # reconnect-retry cost — which we also widened).
                    continue
                now = time.monotonic()
                if now - self._last_set_at < self.KEEPALIVE_GUARD_S:
                    continue
                lat, lng = self.last_lat_lng
                self._keepalive_tick_count += 1
                # v1.15.2 audit (W4): retries=0. A heartbeat must never
                # hold the call lock through the 3.75 s retry ladder —
                # doing so blocked the user's own teleport / stop
                # behind a background tick, and Navigator.stop() awaits
                # the running loop, so a blip turned "Stop" into a
                # ten-second spinner. The next tick is 3 s away; that
                # IS the retry.
                await self.set(lat, lng, retries=0)
            except asyncio.CancelledError:
                return
            except Exception:
                self._note_keepalive(False)
            else:
                self._note_keepalive(True)


class DvtLocationService(LocationService):
    """iOS 17+ via the DVT LocationSimulation instrument over RSD."""

    # Backoff schedule for `set()` retries. Five attempts total
    # (attempt 0 has no sleep), cumulative ~3.75 s wait before
    # bubbling the RuntimeError up to the GUI. Replaces the older
    # one-and-done retry — covers transient WiFi blips and the
    # iPhone-just-came-back-from-screen-lock first call.
    _RETRY_BACKOFFS_S = (0.0, 0.25, 0.5, 1.0, 2.0)

    def __init__(self, dvt_provider: DvtProvider, rsd_lockdown,
                 on_provider_replaced=None) -> None:
        self._dvt = dvt_provider
        self._rsd = rsd_lockdown
        # v1.15.2 audit (W2): `_reconnect()` swaps `self._dvt` for a
        # brand-new provider, but DeviceManager kept its own reference
        # in `sess.dvt_provider`. Teardown therefore closed the already
        # closed original and left the live one open, holding the
        # iPhone's tunnel slot — which is exactly the 30-90 s "refuses
        # a new tunnel" window documented in _teardown_session. With
        # the retry ladder doing up to four reconnects per failed
        # set(), a minute of flaky WiFi could strand dozens. This hook
        # lets the session follow the swap.
        self._on_provider_replaced = on_provider_replaced
        self._sim: LocationSimulation | None = None
        self._reconnect_lock = asyncio.Lock()
        # Serialises real set() vs keepalive set() so they can't race
        # the underlying DVT instrument. Without this, the keepalive
        # tick and a Navigator tick on different asyncio Tasks can
        # both grab the same _sim and step on each other.
        self._call_lock = asyncio.Lock()
        self.last_lat_lng = None

    async def _instrument(self) -> LocationSimulation:
        if self._sim is None:
            sim = LocationSimulation(self._dvt)
            await sim.connect()
            self._sim = sim
            log.debug("DVT LocationSimulation connected")
        return self._sim

    async def _reconnect(self) -> None:
        """Tear down and rebuild the DVT provider once on a transient drop.

        Now called from inside the `set()` retry loop — see
        `_RETRY_BACKOFFS_S`. Each call replaces the underlying DVT
        provider so the next instrument fetch wakes a fresh channel.
        """
        async with self._reconnect_lock:
            try:
                await self._dvt.__aexit__(None, None, None)
            except Exception:
                pass
            self._sim = None

            new_dvt = DvtProvider(self._rsd)
            await new_dvt.__aenter__()
            self._dvt = new_dvt
            if self._on_provider_replaced is not None:
                try:
                    self._on_provider_replaced(new_dvt)
                except Exception:
                    log.exception(
                        "on_provider_replaced hook failed; the old "
                        "provider reference may leak on teardown"
                    )
            log.info("DVT provider reconnected")

    async def set(self, lat: float, lng: float, *,
                  retries: Optional[int] = None) -> None:
        # `retries=None` -> the full ladder (user-visible operations
        # deserve the patience). `retries=0` -> one attempt, no sleep,
        # no channel rebuild: what the keepalive wants.
        backoffs = (
            self._RETRY_BACKOFFS_S if retries is None
            else self._RETRY_BACKOFFS_S[:max(1, retries + 1)]
        )
        async with self._call_lock:
            last_exc: Optional[BaseException] = None
            for attempt, sleep_before in enumerate(backoffs):
                if sleep_before > 0:
                    await asyncio.sleep(sleep_before)
                try:
                    if attempt > 0:
                        # Every retry first rebuilds the DVT pipe — the
                        # whole point of the retry is to recover from a
                        # dead channel, not to ask the dead one again.
                        await self._reconnect()
                    sim = await self._instrument()
                    await sim.set(lat, lng)
                except _RECOVERABLE as exc:
                    last_exc = exc
                    log.warning(
                        "DVT channel dropped (attempt %d/%d, %s)",
                        attempt + 1, len(backoffs),
                        type(exc).__name__,
                    )
                    continue
                # Success. Log at DEBUG when this is a keepalive
                # re-push (same coord as before) so the 3-s heartbeat
                # doesn't spam INFO; INFO for actual movement.
                prev = self.last_lat_lng
                self.last_lat_lng = (lat, lng)
                self._last_set_at = time.monotonic()
                if attempt > 0:
                    log.info("DVT set succeeded after %d retr%s",
                             attempt, "y" if attempt == 1 else "ies")
                if prev == (lat, lng):
                    # Heartbeat: DEBUG by default, INFO every Nth tick
                    # so the default log still proves the loop is alive.
                    tick = self._keepalive_tick_count
                    if tick > 0 and tick % self.KEEPALIVE_INFO_EVERY == 0:
                        log.info(
                            "DVT location keepalive at (%.6f, %.6f) [tick %d]",
                            lat, lng, tick,
                        )
                    else:
                        log.debug("DVT location keepalive at (%.6f, %.6f)",
                                  lat, lng)
                else:
                    log.info("DVT location set to (%.6f, %.6f)", lat, lng)
                return
            # All retries exhausted. The underlying transport is gone.
            # On iOS 26 over WiFi this almost always means "user yanked
            # the USB cable while the WiFi-with-USB-DVT-fallback was
            # running" — the WiFi tunnel alone can't host
            # dt.simulatelocation on this firmware, so the fallback
            # was riding the USB tunnel, and unplug killed it. Surface
            # a message the GUI can show verbatim instead of a generic
            # timeout.
            raise RuntimeError(
                "Lost connection to iPhone location service. "
                "On iOS 17+, the USB cable must stay plugged in — "
                "the WiFi tunnel alone can't reach the simulator on "
                "this iOS version. Reconnect the cable and try again."
            ) from last_exc

    async def clear(self) -> None:
        async with self._call_lock:
            try:
                sim = await self._instrument()
                await sim.clear()
            except _RECOVERABLE as exc:
                log.warning("DVT clear failed (%s); reconnecting",
                            type(exc).__name__)
                try:
                    await self._reconnect()
                    sim = await self._instrument()
                    await sim.clear()
                except _RECOVERABLE:
                    # clear() runs during teardown; if the transport is
                    # already dead just log and move on so disconnect()
                    # doesn't propagate a noisy traceback.
                    log.warning(
                        "DVT clear couldn't reach the iPhone (transport gone); "
                        "skipping — the next Connect will reset the simulation."
                    )
            self.last_lat_lng = None
            log.info("DVT location cleared")


class LegacyLocationService(LocationService):
    """iOS 16.x via DtSimulateLocation over plain usbmux lockdown."""

    def __init__(self, lockdown) -> None:
        self._lockdown = lockdown
        self._svc: DtSimulateLocation | None = None
        self._call_lock = asyncio.Lock()
        self.last_lat_lng = None

    def _service(self) -> DtSimulateLocation:
        if self._svc is None:
            self._svc = DtSimulateLocation(self._lockdown)
        return self._svc

    @staticmethod
    async def _maybe_await(result) -> None:
        if inspect.isawaitable(result):
            await result

    async def set(self, lat: float, lng: float, *,
                  retries: Optional[int] = None) -> None:
        async with self._call_lock:
            try:
                await self._maybe_await(self._service().set(lat, lng))
            except _RECOVERABLE:
                if retries == 0:
                    # Heartbeat: don't rebuild the service under the
                    # lock, just report and let the next tick try.
                    raise
                self._svc = None
                await self._maybe_await(self._service().set(lat, lng))
            prev = self.last_lat_lng
            self.last_lat_lng = (lat, lng)
            self._last_set_at = time.monotonic()
            if prev == (lat, lng):
                tick = self._keepalive_tick_count
                if tick > 0 and tick % self.KEEPALIVE_INFO_EVERY == 0:
                    log.info(
                        "Legacy location keepalive at (%.6f, %.6f) [tick %d]",
                        lat, lng, tick,
                    )
                else:
                    log.debug("Legacy location keepalive at (%.6f, %.6f)",
                              lat, lng)
            else:
                log.info("Legacy location set to (%.6f, %.6f)", lat, lng)

    async def clear(self) -> None:
        async with self._call_lock:
            try:
                await self._maybe_await(self._service().clear())
            except _RECOVERABLE:
                self._svc = None
                await self._maybe_await(self._service().clear())
            self.last_lat_lng = None
            log.info("Legacy location cleared")
