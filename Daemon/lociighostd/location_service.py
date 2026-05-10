"""Inject simulated GPS coordinates into a connected iPhone.

Two implementations exist because iOS draws the line at 17.0:

* **DvtLocationService** (iOS 17+) talks to the DVT `LocationSimulation`
  instrument through an established RSD tunnel. This is the same channel
  Xcode uses internally.
* **LegacyLocationService** (iOS 16.x) uses the older
  `com.apple.dt.simulatelocation` lockdown service over plain usbmux.

Both expose the same async interface (`set` / `clear`), so the calling
code never has to know which one it's holding.
"""

from __future__ import annotations

import asyncio
import inspect
import logging
from abc import ABC, abstractmethod
from typing import Optional

from pymobiledevice3.exceptions import ConnectionTerminatedError
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.simulate_location import DtSimulateLocation

log = logging.getLogger(__name__)


# Network errors that often mean "the channel died, reconnect and try again".
_RECOVERABLE = (
    ConnectionTerminatedError,
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

    @abstractmethod
    async def set(self, lat: float, lng: float) -> None: ...

    @abstractmethod
    async def clear(self) -> None: ...


class DvtLocationService(LocationService):
    """iOS 17+ via the DVT LocationSimulation instrument over RSD."""

    def __init__(self, dvt_provider: DvtProvider, rsd_lockdown) -> None:
        self._dvt = dvt_provider
        self._rsd = rsd_lockdown
        self._sim: LocationSimulation | None = None
        self._reconnect_lock = asyncio.Lock()
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

        The original LociiGhost goes through several retries here; we keep it
        deliberately short. A single retry covers the common screen-lock
        blip; if it fails twice the device is almost certainly gone and
        bubbling up is more useful than blocking on backoffs.
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
            log.info("DVT provider reconnected")

    async def set(self, lat: float, lng: float) -> None:
        try:
            sim = await self._instrument()
            await sim.set(lat, lng)
        except _RECOVERABLE as exc:
            log.warning("DVT channel dropped (%s); reconnecting", type(exc).__name__)
            try:
                await self._reconnect()
                sim = await self._instrument()
                await sim.set(lat, lng)
            except _RECOVERABLE as fatal:
                # The underlying transport is gone. On iOS 26 over WiFi
                # this almost always means "user yanked the USB cable
                # while the WiFi-with-USB-DVT-fallback was running" —
                # the WiFi tunnel alone can't host dt.simulatelocation
                # on this firmware, so the fallback was riding the USB
                # tunnel, and unplug killed it. Surface a message the
                # GUI can show verbatim instead of a generic timeout.
                raise RuntimeError(
                    "Lost connection to iPhone location service. "
                    "On iOS 17+, the USB cable must stay plugged in — "
                    "the WiFi tunnel alone can't reach the simulator on "
                    "this iOS version. Reconnect the cable and try again."
                ) from fatal
        # Track last successful position so callers (notably the
        # phone-side `/api/phone/navigate` endpoint, which has no
        # local map state to consult) can use it as the route origin.
        self.last_lat_lng = (lat, lng)
        log.info("DVT location set to (%.6f, %.6f)", lat, lng)

    async def clear(self) -> None:
        try:
            sim = await self._instrument()
            await sim.clear()
        except _RECOVERABLE as exc:
            log.warning("DVT clear failed (%s); reconnecting", type(exc).__name__)
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
        self.last_lat_lng = None

    def _service(self) -> DtSimulateLocation:
        if self._svc is None:
            self._svc = DtSimulateLocation(self._lockdown)
        return self._svc

    @staticmethod
    async def _maybe_await(result) -> None:
        if inspect.isawaitable(result):
            await result

    async def set(self, lat: float, lng: float) -> None:
        try:
            await self._maybe_await(self._service().set(lat, lng))
        except _RECOVERABLE:
            self._svc = None
            await self._maybe_await(self._service().set(lat, lng))
        self.last_lat_lng = (lat, lng)
        log.info("Legacy location set to (%.6f, %.6f)", lat, lng)

    async def clear(self) -> None:
        try:
            await self._maybe_await(self._service().clear())
        except _RECOVERABLE:
            self._svc = None
            await self._maybe_await(self._service().clear())
        self.last_lat_lng = None
        log.info("Legacy location cleared")
