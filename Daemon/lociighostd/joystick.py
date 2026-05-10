"""Real-time joystick controller.

The Mac side presses W/A/S/D (or moves a virtual stick); the daemon
holds the most recent (heading, speed) and integrates a step on every
tick. When the stick goes neutral the loop simply stops emitting until
a fresh non-zero input arrives, so the iPhone freezes in place
naturally without us having to call clear().

This is the first feature where the daemon's loop is genuinely event-
driven — no preplanned route, no random sampling, just "do whatever
the user says, right now". Idle-friendly: if no key is held, the loop
parks on `_input_event` and burns 0% CPU.
"""

from __future__ import annotations

import asyncio
import logging
import math
from dataclasses import dataclass
from typing import Awaitable, Callable

from .location_service import LocationService

log = logging.getLogger(__name__)

METRES_PER_DEGREE_LAT = 111_000.0


@dataclass(frozen=True, slots=True)
class JoystickStatus:
    state: str                  # "idle" | "moving" | "stopped"
    lat: float
    lng: float
    heading_deg: float          # 0 = north, 90 = east
    speed_mps: float

    def to_json(self) -> dict[str, object]:
        return {
            "state": self.state,
            "lat": self.lat,
            "lng": self.lng,
            "heading_deg": self.heading_deg,
            "speed_mps": self.speed_mps,
        }


EventEmitter = Callable[[str, JoystickStatus], Awaitable[None]]


class JoystickController:
    TICK_S = 0.5

    def __init__(
        self,
        location: LocationService,
        origin: tuple[float, float],
        on_event: EventEmitter | None = None,
    ) -> None:
        self._location = location
        self._current = origin
        self._heading_deg = 0.0
        self._speed_mps = 0.0
        self._state: str = "idle"
        self._on_event = on_event

        self._task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()
        self._input_event = asyncio.Event()
        self._lock = asyncio.Lock()

    @property
    def state(self) -> str:
        return self._state

    def status(self) -> JoystickStatus:
        return JoystickStatus(
            state=self._state,
            lat=self._current[0],
            lng=self._current[1],
            heading_deg=self._heading_deg,
            speed_mps=self._speed_mps,
        )

    def start(self) -> None:
        if self._task is not None:
            return
        self._task = asyncio.create_task(self._run(), name="joystick")

    async def stop(self) -> None:
        self._stop_event.set()
        self._input_event.set()
        if self._task is not None:
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._state = "stopped"

    async def update(self, heading_deg: float, speed_mps: float) -> None:
        """Push a new (heading, speed) into the controller. Either value
        can change between ticks. `speed_mps == 0` parks the loop until
        the next non-zero update."""
        if speed_mps < 0:
            speed_mps = 0.0
        async with self._lock:
            self._heading_deg = heading_deg % 360.0
            self._speed_mps = speed_mps
        # Wake the loop so a paused (speed=0) controller starts moving
        # immediately, without waiting for the next tick interval.
        self._input_event.set()

    # ------------------------------------------------------------------
    # Loop
    # ------------------------------------------------------------------

    async def _run(self) -> None:
        try:
            # Push the origin so the iPhone's first frame in joystick mode
            # is the user's starting position rather than wherever the
            # phone last was.
            await self._location.set(*self._current)
            await self._emit("event.position_update")

            while not self._stop_event.is_set():
                async with self._lock:
                    speed = self._speed_mps
                    heading = self._heading_deg

                if speed <= 0:
                    self._state = "idle"
                    await self._emit("event.state_changed")
                    self._input_event.clear()
                    await self._input_event.wait()
                    continue

                self._state = "moving"
                self._current = self._step(self._current, heading, speed * self.TICK_S)
                await self._location.set(*self._current)
                await self._emit("event.position_update")

                try:
                    await asyncio.wait_for(self._stop_event.wait(), timeout=self.TICK_S)
                    if self._stop_event.is_set():
                        break
                except asyncio.TimeoutError:
                    pass
        finally:
            self._state = "stopped"
            await self._emit("event.state_changed")

    @staticmethod
    def _step(current: tuple[float, float], heading_deg: float, distance_m: float) -> tuple[float, float]:
        """Move `distance_m` from `current` in `heading_deg` (0 = north)."""
        rad = math.radians(heading_deg)
        # Heading 0 is north, so cos -> latitude axis, sin -> longitude axis.
        dlat = (distance_m * math.cos(rad)) / METRES_PER_DEGREE_LAT
        dlng = (distance_m * math.sin(rad)) / (
            METRES_PER_DEGREE_LAT * max(math.cos(math.radians(current[0])), 1e-6)
        )
        return (current[0] + dlat, current[1] + dlng)

    async def _emit(self, method: str) -> None:
        if self._on_event is None:
            return
        try:
            await self._on_event(method, self.status())
        except Exception:
            log.exception("joystick emit failed")
