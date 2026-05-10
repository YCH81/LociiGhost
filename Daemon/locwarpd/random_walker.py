"""Random walk simulation: drift the iPhone around inside a bounded circle.

Picks a random target inside the radius, walks there at a random speed
within the configured band, dwells for a random pause, repeats. The
shape of the trajectory is much more "natural-looking" than the simple
straight-line back-and-forth the M-version did, but the implementation
is still a single async loop with no external state.

Like `Navigator`, this owns one task and exposes start / stop. Pause
isn't supported on purpose -- a random walker is supposed to be a
hands-off "wander in the background" simulation; if the caller wants
fine control, they should use a Navigator instead.
"""

from __future__ import annotations

import asyncio
import logging
import math
import random
from dataclasses import dataclass
from typing import Awaitable, Callable

from .interpolator import haversine_m, route_length_m
from .location_service import LocationService

log = logging.getLogger(__name__)


# 1° latitude ≈ 111 km everywhere on Earth. Longitude scales by cos(lat),
# so we only need this constant.
METRES_PER_DEGREE_LAT = 111_000.0


@dataclass(frozen=True, slots=True)
class RandomWalkStatus:
    state: str                   # "moving" | "stopped"
    center_lat: float
    center_lng: float
    radius_m: float
    lat: float
    lng: float
    speed_mps: float
    distance_traveled_m: float
    planned_path: list[tuple[float, float]]   # upcoming targets, in order

    def to_json(self) -> dict[str, object]:
        return {
            "state": self.state,
            "center_lat": self.center_lat,
            "center_lng": self.center_lng,
            "radius_m": self.radius_m,
            "lat": self.lat,
            "lng": self.lng,
            "speed_mps": self.speed_mps,
            "distance_traveled_m": self.distance_traveled_m,
            "planned_path": [{"lat": lat, "lng": lng} for lat, lng in self.planned_path],
        }


EventEmitter = Callable[[str, RandomWalkStatus], Awaitable[None]]


class RandomWalker:
    """One random-walk session per device."""

    TICK_S = 1.0
    DWELL_RANGE_S = (1.5, 4.0)            # pause between targets
    TARGET_DISTANCE_FRACTION = (0.15, 1.0) # what fraction of radius to aim for
    PLANNED_DURATION_S = 5 * 60           # how far ahead we pre-plan targets

    def __init__(
        self,
        location: LocationService,
        center: tuple[float, float],
        radius_m: float,
        min_speed_mps: float,
        max_speed_mps: float,
        on_event: EventEmitter | None = None,
    ) -> None:
        if radius_m <= 0:
            raise ValueError("radius_m must be > 0")
        if min_speed_mps <= 0 or max_speed_mps <= 0 or min_speed_mps > max_speed_mps:
            raise ValueError("invalid speed band")

        self._location = location
        self._center = center
        self._radius_m = radius_m
        self._min_speed = min_speed_mps
        self._max_speed = max_speed_mps
        self._on_event = on_event

        self._current = center
        self._current_speed = 0.0
        self._distance_total = 0.0
        self._state: str = "idle"
        self._task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()
        # Pre-generate the next ~5 minutes of targets so the GUI can
        # draw the actual upcoming path on the map. We refresh this
        # whenever the queue empties (every 5 minutes of walking).
        self._planned_path: list[tuple[float, float]] = []
        self._regenerate_planned_path()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    @property
    def state(self) -> str:
        return self._state

    def start(self) -> None:
        if self._task is not None:
            return
        self._state = "moving"
        self._task = asyncio.create_task(self._run(), name="random-walker")

    async def stop(self) -> None:
        self._stop_event.set()
        if self._task is not None:
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._state = "stopped"

    def status(self) -> RandomWalkStatus:
        # The planned path the GUI should draw starts at the current
        # position so the visual line connects to where the iPhone is
        # right now, not back at the original center.
        future = [self._current] + list(self._planned_path)
        return RandomWalkStatus(
            state=self._state,
            center_lat=self._center[0],
            center_lng=self._center[1],
            radius_m=self._radius_m,
            lat=self._current[0],
            lng=self._current[1],
            speed_mps=self._current_speed,
            distance_traveled_m=self._distance_total,
            planned_path=future,
        )

    # ------------------------------------------------------------------
    # Loop
    # ------------------------------------------------------------------

    async def _run(self) -> None:
        try:
            await self._location.set(*self._center)
            await self._emit("event.position_update")
            while not self._stop_event.is_set():
                if not self._planned_path:
                    self._regenerate_planned_path()
                    # Tell the GUI a new 5-minute slice has been planned
                    # so it can redraw the upcoming-path polyline.
                    await self._emit("event.state_changed")
                target = self._planned_path.pop(0)
                speed = random.uniform(self._min_speed, self._max_speed)
                self._current_speed = speed
                if not await self._walk_to(target, speed):
                    break
                if self._stop_event.is_set():
                    break
                # Brief dwell so the trajectory looks like a real meander
                # rather than a continuous tour.
                dwell = random.uniform(*self.DWELL_RANGE_S)
                self._current_speed = 0.0
                await self._emit("event.state_changed")
                try:
                    await asyncio.wait_for(self._stop_event.wait(), timeout=dwell)
                    if self._stop_event.is_set():
                        break
                except asyncio.TimeoutError:
                    pass
        finally:
            self._state = "stopped"
            await self._emit("event.state_changed")

    def _regenerate_planned_path(self) -> None:
        """Pre-pick enough random targets to cover the next
        `PLANNED_DURATION_S` of walking at the average configured speed.
        Stored verbatim so the GUI can render the same polyline the
        walker will actually traverse — no hidden randomness between
        what we show and what we walk."""
        avg_speed = max((self._min_speed + self._max_speed) / 2.0, 0.01)
        target_distance = avg_speed * self.PLANNED_DURATION_S

        path: list[tuple[float, float]] = []
        prev = self._current
        travelled = 0.0
        # Cap the segment count so a tiny radius can't lock us in a tight
        # planning loop generating thousands of micro-jumps.
        for _ in range(64):
            if travelled >= target_distance:
                break
            t = self._pick_target()
            path.append(t)
            travelled += haversine_m(prev, t)
            prev = t
        if not path:
            # Degenerate: at minimum give the walker one target to head to.
            path = [self._pick_target()]
        self._planned_path = path

    def _pick_target(self) -> tuple[float, float]:
        """Choose the next destination uniformly within the bounded disc."""
        # Uniform sampling over a disc: radius ~ sqrt(uniform), angle uniform.
        # Skip the very-near range so successive targets are visibly apart.
        lo, hi = self.TARGET_DISTANCE_FRACTION
        r = self._radius_m * math.sqrt(random.uniform(lo, hi))
        theta = random.uniform(0, 2 * math.pi)
        dlat = (r * math.cos(theta)) / METRES_PER_DEGREE_LAT
        dlng = (r * math.sin(theta)) / (
            METRES_PER_DEGREE_LAT * max(math.cos(math.radians(self._center[0])), 1e-6)
        )
        return (self._center[0] + dlat, self._center[1] + dlng)

    async def _walk_to(self, target: tuple[float, float], speed_mps: float) -> bool:
        """Step toward `target` at `speed_mps`. Returns False if interrupted."""
        while not self._stop_event.is_set():
            d = haversine_m(self._current, target)
            step = speed_mps * self.TICK_S
            if d <= step:
                self._distance_total += d
                self._current = target
                await self._location.set(*target)
                await self._emit("event.position_update")
                return True
            frac = step / d
            new_lat = self._current[0] + (target[0] - self._current[0]) * frac
            new_lng = self._current[1] + (target[1] - self._current[1]) * frac
            self._distance_total += step
            self._current = (new_lat, new_lng)
            await self._location.set(new_lat, new_lng)
            await self._emit("event.position_update")
            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=self.TICK_S)
                if self._stop_event.is_set():
                    return False
            except asyncio.TimeoutError:
                pass
        return False

    async def _emit(self, method: str) -> None:
        if self._on_event is None:
            return
        try:
            await self._on_event(method, self.status())
        except Exception:
            log.exception("random walker emit failed")
