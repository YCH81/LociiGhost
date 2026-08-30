"""Run a navigation along a route at a given speed.

The `Navigator` is the only thing that calls `LocationService.set` on a
schedule. It owns a single asyncio task and a small set of asyncio
primitives for pause / resume / stop / hot-swap-speed.

Design: do not pre-compute the whole tick stream. We compute the next
position lazily each iteration so changing speed mid-route is a one-
line update (`self._speed_mps = new`) — no need to re-build the
generator. We also honour the stop/pause flags between ticks instead
of trying to interrupt a long sleep, which keeps the cancellation
behaviour predictable.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from typing import Awaitable, Callable, Optional

from .interpolator import haversine_m, route_length_m
from .location_service import LocationService

log = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class NavigationStatus:
    state: str                          # "idle" | "moving" | "paused" | "stopped"
    profile: str
    speed_mps: float
    lat: float
    lng: float
    cumulative_m: float
    distance_m: float                   # total route length
    eta_s: float                        # remaining seconds at current speed
    # v1.15.2 audit (W9): _run() had only try/finally, so a set() that
    # raised (which W1 made far more likely to actually happen) killed
    # the task, emitted a bare state change, and left the user with a
    # route that simply stopped for no stated reason plus a "Task
    # exception was never retrieved" in the daemon log.
    error: Optional[str] = None

    def to_json(self) -> dict[str, object]:
        return {
            "state": self.state,
            "error": self.error,
            "profile": self.profile,
            "speed_mps": self.speed_mps,
            "lat": self.lat,
            "lng": self.lng,
            "cumulative_m": self.cumulative_m,
            "distance_m": self.distance_m,
            "eta_s": self.eta_s,
            "progress": (self.cumulative_m / self.distance_m) if self.distance_m > 0 else 1.0,
        }


# Async callback signature. The simulation engine passes one in so
# state changes and position updates can be broadcast to RPC clients
# without the navigator caring about transport.
EventEmitter = Callable[[str, NavigationStatus], Awaitable[None]]


class Navigator:
    """One per active navigation. Lives on the device session.

    Use `start()` to fire the loop, then `pause()` / `resume()` / `stop()`
    or `apply_speed()` from the outside. `wait()` blocks until the loop
    has finished (either by reaching the end or by stop()).
    """

    TICK_S = 1.0           # how often we push a position to the iPhone

    # v1.15.2 audit (W8): upper bound on the elapsed time a single tick
    # may claim. Without it, resuming from a long pause (or the loop
    # being starved while another coroutine held the location call
    # lock) would advance the iPhone by the entire gap in one jump.
    MAX_TICK_CATCHUP_S = 5.0

    def __init__(
        self,
        location: LocationService,
        coords: list[tuple[float, float]],
        speed_mps: float,
        profile: str,
        on_event: EventEmitter | None = None,
    ) -> None:
        if len(coords) < 2:
            raise ValueError("route needs at least 2 coordinates")
        if speed_mps <= 0:
            raise ValueError("speed_mps must be > 0")
        self._location = location
        self._coords = list(coords)
        self._speed_mps = speed_mps
        self._profile = profile
        self._on_event = on_event

        self._total_distance = route_length_m(self._coords)
        self._cumulative = 0.0
        self._seg_idx = 0
        self._seg_done = 0.0
        # Cache segment length — recomputed when seg_idx advances.
        self._seg_len = haversine_m(self._coords[0], self._coords[1])

        self._state: str = "idle"
        self._error: Optional[str] = None
        # Wall-clock anchor for elapsed-time stepping (W8). None means
        # "next tick is the first one" — used at start and after every
        # pause so a pause is never mistaken for travel time.
        self._last_tick_at: Optional[float] = None
        self._task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()
        self._resume_event = asyncio.Event()
        self._resume_event.set()        # not paused → resume gate is open
        self._lock = asyncio.Lock()

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
        self._task = asyncio.create_task(self._run(), name="navigator")

    async def wait(self) -> None:
        if self._task is not None:
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def stop(self) -> None:
        self._stop_event.set()
        # Unblock the resume gate so a paused loop can observe stop.
        self._resume_event.set()
        await self.wait()
        self._state = "stopped"

    async def pause(self) -> None:
        if self._state != "moving":
            return
        self._resume_event.clear()
        self._state = "paused"
        await self._emit("event.state_changed")

    async def resume(self) -> None:
        if self._state != "paused":
            return
        self._resume_event.set()
        # W8: drop the anchor so the paused interval isn't billed as
        # travel time on the first tick back.
        self._last_tick_at = None
        self._state = "moving"
        await self._emit("event.state_changed")

    async def apply_speed(self, new_speed_mps: float) -> None:
        """Hot-swap speed. The next tick recomputes step distance from
        the new value, so the iPhone immediately accelerates/decelerates."""
        if new_speed_mps <= 0:
            raise ValueError("speed_mps must be > 0")
        async with self._lock:
            self._speed_mps = new_speed_mps
        await self._emit("event.state_changed")

    # ------------------------------------------------------------------
    # Snapshot / event helpers
    # ------------------------------------------------------------------

    def status(self) -> NavigationStatus:
        if self._cumulative >= self._total_distance or not self._coords:
            lat, lng = self._coords[-1]
        else:
            lat, lng = self._current_position()
        remaining = max(0.0, self._total_distance - self._cumulative)
        eta = remaining / self._speed_mps if self._speed_mps > 0 else 0.0
        return NavigationStatus(
            state=self._state,
            error=self._error,
            profile=self._profile,
            speed_mps=self._speed_mps,
            lat=lat,
            lng=lng,
            cumulative_m=self._cumulative,
            distance_m=self._total_distance,
            eta_s=eta,
        )

    async def _emit(self, method: str) -> None:
        if self._on_event is None:
            return
        try:
            await self._on_event(method, self.status())
        except Exception:
            log.exception("navigator event emit failed")

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    def _current_position(self) -> tuple[float, float]:
        """Interpolated (lat, lng) at our current `seg_done`."""
        a = self._coords[self._seg_idx]
        b = self._coords[self._seg_idx + 1]
        if self._seg_len <= 0:
            return a
        frac = min(1.0, self._seg_done / self._seg_len)
        lat = a[0] + (b[0] - a[0]) * frac
        lng = a[1] + (b[1] - a[1]) * frac
        return lat, lng

    async def _run(self) -> None:
        try:
            # Push the start point so the iPhone immediately reflects the
            # beginning of the route.
            start = self._coords[0]
            await self._location.set(start[0], start[1])
            await self._emit("event.position_update")

            while True:
                if self._stop_event.is_set():
                    break

                # Pause gate. The loop sleeps cheaply on resume_event.
                if not self._resume_event.is_set():
                    await self._resume_event.wait()
                    if self._stop_event.is_set():
                        break
                    # W8: however long we were parked here, it wasn't
                    # travel. resume() clears this too, but a stop that
                    # races the resume can land us here directly.
                    self._last_tick_at = None

                tick_started_at = time.monotonic()
                async with self._lock:
                    speed = self._speed_mps
                # v1.15.2 audit (W8): advance by the time that actually
                # elapsed, not by the nominal tick. The old code paired
                # a fixed `speed * TICK_S` step with a comment claiming
                # the deadline was computed up front so a slow set()
                # wouldn't drift — but the deadline was computed AFTER
                # set() returned, so `remaining` was always exactly
                # TICK_S. A set() that took four seconds therefore
                # advanced the same distance as one that took ten
                # milliseconds: on a flaky link the iPhone crawled at a
                # fraction of the requested speed while the ETA, which
                # divides by the nominal speed, kept lying about it.
                if self._last_tick_at is None:
                    elapsed = self.TICK_S
                else:
                    elapsed = min(tick_started_at - self._last_tick_at,
                                  self.MAX_TICK_CATCHUP_S)
                self._last_tick_at = tick_started_at
                step_m = speed * max(0.0, elapsed)

                advanced = self._advance(step_m)
                if not advanced:
                    # Reached the end.
                    end = self._coords[-1]
                    self._cumulative = self._total_distance
                    await self._location.set(end[0], end[1])
                    await self._emit("event.position_update")
                    break

                lat, lng = self._current_position()
                await self._location.set(lat, lng)
                await self._emit("event.position_update")

                # Sleep until the next tick. The deadline is anchored
                # to when this tick STARTED, so a slow set() eats into
                # the sleep instead of pushing the whole cadence back.
                remaining = (tick_started_at + self.TICK_S) - time.monotonic()
                if remaining > 0:
                    try:
                        await asyncio.wait_for(self._stop_event.wait(), timeout=remaining)
                        if self._stop_event.is_set():
                            break
                    except asyncio.TimeoutError:
                        pass
        except asyncio.CancelledError:
            self._state = "stopped"
            await self._emit("event.state_changed")
            raise
        except Exception as exc:
            # W9: report, don't vanish. "failed" deliberately is not
            # "idle" — the Mac treats idle as natural completion and
            # would start the next lap on top of a broken channel.
            self._error = f"{type(exc).__name__}: {exc}"
            self._state = "failed"
            log.exception("navigation loop failed for this route")
            await self._emit("event.state_changed")
            return
        self._state = "idle" if not self._stop_event.is_set() else "stopped"
        await self._emit("event.state_changed")

    def _advance(self, step_m: float) -> bool:
        """Move forward by `step_m` along the polyline. Returns False when
        we're past the end (route complete)."""
        if self._seg_idx >= len(self._coords) - 1:
            return False
        remaining = step_m
        while remaining > 0:
            if self._seg_idx >= len(self._coords) - 1:
                return False
            seg_left = max(0.0, self._seg_len - self._seg_done)
            if remaining < seg_left:
                self._seg_done += remaining
                self._cumulative += remaining
                return True
            # consume the rest of this segment, advance to next
            self._cumulative += seg_left
            remaining -= seg_left
            self._seg_idx += 1
            self._seg_done = 0.0
            if self._seg_idx < len(self._coords) - 1:
                self._seg_len = haversine_m(
                    self._coords[self._seg_idx],
                    self._coords[self._seg_idx + 1],
                )
        return self._seg_idx < len(self._coords) - 1
