"""Shared doubles for the movement-lifecycle tests.

Everything the movers touch is either a location service or an event
emitter, so a recording stand-in for each is enough to assert on
ordering, cancellation and who-was-driving without an iPhone.
"""
from __future__ import annotations

import asyncio
from typing import Any, Optional

from lociighostd.device_manager import _Session
from lociighostd.location_service import LocationService


class FakeLocation(LocationService):
    """Records every coordinate pushed, in order.

    `delay` simulates a slow DVT channel; `fail_after` makes every call
    past the Nth raise, which is how we exercise the failure paths that
    used to be silent.
    """

    def __init__(self, delay: float = 0.0, fail_after: Optional[int] = None,
                 exc: Optional[BaseException] = None) -> None:
        self.calls: list[tuple[float, float]] = []
        self.cleared = 0
        self.delay = delay
        self.fail_after = fail_after
        self.exc = exc or RuntimeError("fake channel down")
        self._call_lock = asyncio.Lock()
        self.last_lat_lng = None

    async def set(self, lat: float, lng: float, *,
                  retries: Optional[int] = None) -> None:
        async with self._call_lock:
            if self.delay:
                await asyncio.sleep(self.delay)
            if self.fail_after is not None and len(self.calls) >= self.fail_after:
                raise self.exc
            self.calls.append((lat, lng))
            self.last_lat_lng = (lat, lng)
            self._last_set_at = asyncio.get_running_loop().time()

    async def clear(self) -> None:
        async with self._call_lock:
            self.cleared += 1
            self.last_lat_lng = None


class FakeRunner:
    """Stands in for Navigator / RandomWalker / JoystickController."""

    def __init__(self, name: str = "fake", stop_delay: float = 0.0) -> None:
        self.name = name
        self.started = False
        self.stopped = False
        self.stop_delay = stop_delay
        self._task: Optional[asyncio.Task] = None
        self._stop_event = asyncio.Event()
        self.ticks = 0

    def start(self) -> None:
        self.started = True
        self._task = asyncio.create_task(self._run(), name=self.name)

    async def _run(self) -> None:
        try:
            while not self._stop_event.is_set():
                self.ticks += 1
                await asyncio.sleep(0.01)
        except asyncio.CancelledError:
            raise

    async def stop(self) -> None:
        self._stop_event.set()
        if self.stop_delay:
            await asyncio.sleep(self.stop_delay)
        if self._task is not None:
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self.stopped = True


def make_session(manager, udid: str = "UDID-1", **kw) -> _Session:
    """Register a minimally-populated connected session on `manager`."""
    sess = _Session(
        udid=udid,
        ios_version=kw.pop("ios_version", "17.4"),
        name=kw.pop("name", "Test iPhone"),
        transport=kw.pop("transport", "usb"),
        usbmux_lockdown=None,
    )
    for k, v in kw.items():
        setattr(sess, k, v)
    manager._sessions[udid] = sess          # noqa: SLF001
    return sess
