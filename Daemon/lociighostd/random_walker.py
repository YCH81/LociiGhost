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

from .interpolator import haversine_m, normalize_latlng
from .location_service import LocationService
from .routing import NoRouteError, OsrmClient, RoutingError

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

    def __init__(
        self,
        location: LocationService,
        center: tuple[float, float],
        radius_m: float,
        min_speed_mps: float,
        max_speed_mps: float,
        on_event: EventEmitter | None = None,
        osrm: OsrmClient | None = None,
        routing_engine: str = "straight",
        profile: str = "walking",
        dwell_seconds_override: float | None = None,
    ) -> None:
        if radius_m <= 0:
            raise ValueError("radius_m must be > 0")
        if min_speed_mps <= 0 or max_speed_mps <= 0 or min_speed_mps > max_speed_mps:
            raise ValueError("invalid speed band")
        if routing_engine not in ("straight", "map"):
            raise ValueError(f"routing_engine must be 'straight' or 'map', got {routing_engine!r}")
        if dwell_seconds_override is not None and dwell_seconds_override <= 0:
            raise ValueError("dwell_seconds_override must be > 0 when set")

        self._location = location
        self._center = center
        self._radius_m = radius_m
        self._min_speed = min_speed_mps
        self._max_speed = max_speed_mps
        self._on_event = on_event
        self._osrm = osrm
        self._routing_engine = routing_engine if osrm is not None else "straight"
        self._profile = profile
        # Optional fixed dwell time between targets. When None we use
        # the random 1.5-4 s range that gives the meander an organic
        # feel; the user can override with a fixed N seconds via the
        # multi-stop dwell control to make the walker pause longer at
        # every target (useful for location-based event captures).
        self._dwell_seconds_override = dwell_seconds_override

        self._current = center
        self._current_speed = 0.0
        self._distance_total = 0.0
        self._state: str = "idle"
        self._task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()
        # v1.11.0: per-leg JIT planning. Each iteration of `_run` picks
        # ONE random target then resolves the polyline (OSRM in map
        # mode, straight-line in straight mode) just for that leg.
        # On arrival the walker dwells, then plans the next leg.
        # The status emission's planned_path is therefore exactly the
        # upcoming leg's polyline — what the GUI draws matches what
        # the walker traverses, with no five-minute look-ahead tangle
        # of crossing lines that confused users in the earlier model.
        self._current_target: tuple[float, float] | None = None
        self._current_polyline: list[tuple[float, float]] = []

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
        # The planned path the GUI should draw is the upcoming leg's
        # polyline, prepended with the current position so the line
        # visually anchors to where the iPhone is right now.
        future = [self._current] + list(self._current_polyline)
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
                # Plan the next leg if we don't have one queued.
                if not self._current_polyline:
                    await self._plan_next_leg()
                    # Tell the GUI the upcoming leg's polyline so it can
                    # draw a clean "where I'm heading next" line.
                    await self._emit("event.state_changed")
                # Walk through every polyline waypoint of this leg
                # at the same chosen speed, with no inter-waypoint
                # dwell — they're just road shape points, not real
                # destinations. The single dwell happens after we've
                # consumed all polyline waypoints, i.e. on arrival
                # at the target.
                speed = random.uniform(self._min_speed, self._max_speed)
                self._current_speed = speed
                arrived = True
                while self._current_polyline and not self._stop_event.is_set():
                    waypoint = self._current_polyline[0]
                    if not await self._walk_to(waypoint, speed):
                        arrived = False
                        break
                    # Pop only after we've actually completed the segment
                    # so a Stop mid-segment leaves the queue describing
                    # what we still owe the user (not strictly needed for
                    # walker correctness, but it keeps status emissions
                    # accurate during the shutdown window).
                    if self._current_polyline:
                        self._current_polyline.pop(0)
                if not arrived or self._stop_event.is_set():
                    break
                # Arrived at the leg's target. Dwell before planning the
                # next one — fixed-N seconds if the user enabled the
                # dwell control, otherwise a random 1.5–4 s for the
                # organic-meander feel.
                if self._dwell_seconds_override is not None:
                    dwell = self._dwell_seconds_override
                else:
                    dwell = random.uniform(*self.DWELL_RANGE_S)
                self._current_speed = 0.0
                self._current_target = None
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

    async def _plan_next_leg(self) -> None:
        """Pick one random target inside the disc and (in map mode)
        resolve its OSRM polyline. Populates `_current_target` and
        `_current_polyline`; the latter is what `_run` walks through
        and what `status()` exposes to the GUI."""
        target = self._pick_target()
        self._current_target = target

        if self._routing_engine == "map" and self._osrm is not None:
            try:
                route = await self._osrm.route(
                    from_lat=self._current[0],
                    from_lng=self._current[1],
                    to_lat=target[0],
                    to_lng=target[1],
                    profile=self._profile,
                )
            except (NoRouteError, RoutingError) as exc:
                log.info("osrm leg planning failed (%s); using straight target", exc)
                self._current_polyline = [target]
                return
            except Exception:
                log.exception("osrm leg planning raised unexpectedly")
                self._current_polyline = [target]
                return
            # Drop the duplicate origin point — we're already at the
            # first coord (we passed it in as `from_lat`/`from_lng`),
            # so walking to it again would no-op the first tick.
            pts = route.coordinates[1:] if route.coordinates else []
            self._current_polyline = pts if pts else [target]
        else:
            self._current_polyline = [target]

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
        return normalize_latlng(self._center[0] + dlat,
                                self._center[1] + dlng)

    async def _walk_to(self, target: tuple[float, float], speed_mps: float) -> bool:
        """Step toward `target` at `speed_mps`. Returns False if interrupted.

        In map mode, the `_planned_path` is already an expanded OSRM
        polyline (dense road waypoints), so straight-line interpolation
        between adjacent waypoints visually traces real roads. In
        straight mode, the planned path is sparse random targets and
        the same interpolator hops directly between them.
        """
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
