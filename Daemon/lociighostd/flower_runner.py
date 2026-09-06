"""Run a flower plan on one device.

`flower_plan` decides where the device goes; this walks it there and
reports progress. Same shape as `RandomWalker` — one task, start/stop,
a status the GUI polls and receives as events — because the device
manager stops whatever is moving a phone by calling `stop()` on it, and
a runner that doesn't fit that shape is a runner that keeps ticking
after Stop.

Progress is one integer: how many steps of the plan are done. The plan
is deterministic in (waypoints, settings), so resuming after a dropped
connection is re-planning and skipping ahead — there is no partial
route to persist and nothing to get out of sync.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Awaitable, Callable

from .flower_plan import FlowerSettings, FlowerStep, estimate_seconds, plan, resume_from
from .location_service import LocationService
from .movement import sleep_or_stop, walk_segment

log = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class FlowerStatus:
    state: str                       # "moving" | "waiting" | "stopped"
    lat: float
    lng: float
    speed_mps: float
    distance_traveled_m: float
    step_index: int                  # steps completed
    total_steps: int
    point_index: int
    round_index: int
    rounds: int
    points: int
    eta_seconds: float               # for what is left, not the whole run
    planned_path: list[tuple[float, float]]

    def to_json(self) -> dict[str, object]:
        return {
            "state": self.state,
            "lat": self.lat,
            "lng": self.lng,
            "speed_mps": self.speed_mps,
            "distance_traveled_m": self.distance_traveled_m,
            "step_index": self.step_index,
            "total_steps": self.total_steps,
            "point_index": self.point_index,
            "round_index": self.round_index,
            "rounds": self.rounds,
            "points": self.points,
            "eta_seconds": self.eta_seconds,
            "planned_path": [{"lat": lat, "lng": lng} for lat, lng in self.planned_path],
        }


EventEmitter = Callable[[str, FlowerStatus], Awaitable[None]]


class FlowerRunner:
    """One flower-mode session per device."""

    TICK_S = 1.0

    MAX_DRAWN_PATH = 60
    """How many upcoming vertices the status hands the GUI. A 20-segment
    ring times 50 laps is a thousand points that all land on the same
    circle; drawing them costs a redraw and shows the user nothing the
    first lap didn't."""

    def __init__(
        self,
        location: LocationService,
        centers: list[tuple[float, float]],
        settings: FlowerSettings,
        on_event: EventEmitter | None = None,
        start_position: tuple[float, float] | None = None,
        completed_steps: int = 0,
    ) -> None:
        if not centers:
            raise ValueError("flower mode needs at least one waypoint")

        self._location = location
        self._centers = list(centers)
        self._settings = settings
        self._on_event = on_event

        self._steps: list[FlowerStep] = plan(self._centers, settings)
        self._completed = max(0, min(completed_steps, len(self._steps)))
        self._current = start_position or centers[0]
        self._current_speed = 0.0
        self._distance_total = 0.0
        self._state = "idle"
        self._task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()
        # Set means "keep going". Same shape as Navigator's, so the
        # RPC means the same thing whichever runner is moving: the
        # phone holds its position and the plan resumes from there,
        # rather than the run being torn down and restarted.
        self._resume_event = asyncio.Event()
        self._resume_event.set()

    # ── Lifecycle ───────────────────────────────────────────────────

    @property
    def state(self) -> str:
        return self._state

    def start(self) -> None:
        if self._task is not None:
            return
        self._state = "moving"
        self._task = asyncio.create_task(self._run(), name="flower-runner")

    async def pause(self) -> bool:
        """Hold position. Returns whether it actually applied.

        Refused unless something is genuinely in motion — a pause that
        lands after the last vertex used to leave the Mac rendering
        "paused" over a run that had already finished, with a resume
        that did nothing either.
        """
        if self._state not in ("moving", "waiting"):
            return False
        self._resume_event.clear()
        self._state = "paused"
        self._current_speed = 0.0
        await self._emit("event.state_changed")
        return True

    async def resume(self) -> bool:
        """Carry on from where the ring was left."""
        if self._state != "paused":
            return False
        self._state = "moving"
        self._resume_event.set()
        await self._emit("event.state_changed")
        return True

    async def stop(self) -> None:
        # A stop must not be swallowed by a pause: release the gate
        # first so a waiting loop wakes up and sees the stop.
        self._resume_event.set()
        self._stop_event.set()
        if self._task is not None:
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._state = "stopped"

    def status(self) -> FlowerStatus:
        remaining = resume_from(self._steps, self._completed)
        step = remaining[0] if remaining else None
        return FlowerStatus(
            state=self._state,
            lat=self._current[0],
            lng=self._current[1],
            speed_mps=self._current_speed,
            distance_traveled_m=self._distance_total,
            step_index=self._completed,
            total_steps=len(self._steps),
            # When the run is finished there is no next step; report the
            # last one worked on rather than 0, which would read as
            # "back at the first waypoint".
            point_index=step.point_index if step else self._steps[-1].point_index,
            round_index=step.round_index if step else self._settings.rounds - 1,
            rounds=self._settings.rounds,
            points=len(self._centers),
            eta_seconds=estimate_seconds(remaining, self._settings, origin=self._current),
            planned_path=[self._current] + self._upcoming_path(remaining),
        )

    def _upcoming_path(self, remaining: list[FlowerStep]) -> list[tuple[float, float]]:
        """The rest of the ring the device is on, for the map to draw.

        Stops at the next hop to another waypoint: drawing the whole
        run would put a straight line across the city through every
        ring, which tells the user nothing about where the phone is
        going next.
        """
        out: list[tuple[float, float]] = []
        for index, step in enumerate(remaining[: self.MAX_DRAWN_PATH]):
            if index > 0 and step.kind == "travel":
                break
            out.append((step.lat, step.lng))
        return out

    # ── Loop ────────────────────────────────────────────────────────

    async def _run(self) -> None:
        try:
            for step in resume_from(self._steps, self._completed):
                if self._stop_event.is_set():
                    break
                if not await self._await_resume():
                    break
                if not await self._go_to(step):
                    break
                if not await self._wait_after(step):
                    break
                self._completed += 1
            else:
                # Ran the whole plan without a break: a completed run,
                # not an interrupted one.
                self._current_speed = 0.0
        finally:
            self._state = "stopped"
            self._current_speed = 0.0
            await self._emit("event.state_changed")

    async def _go_to(self, step: FlowerStep) -> bool:
        target = (step.lat, step.lng)
        teleporting = step.kind == "travel" and self._settings.teleport_between

        self._state = "moving"
        if teleporting:
            # A teleport covers no ground the user asked to walk, so it
            # doesn't count toward distance travelled — otherwise the
            # readout says the phone walked 24 km it never walked.
            self._current = target
            self._current_speed = 0.0
            await self._location.set(*target)
            await self._emit("event.position_update")
            return not self._stop_event.is_set()

        self._current_speed = self._settings.speed_mps

        async def on_step(position: tuple[float, float], covered_m: float) -> None:
            # Gate BEFORE the push, not after. The walk loop wakes from
            # its tick sleep with the next position already computed,
            # so gating afterwards let one more coordinate out the door
            # — the phone took a final step after the user had pressed
            # pause. Holding here parks that position until resume, and
            # `walk_segment` advances by a fixed distance per tick
            # rather than by wall clock, so the wait never makes the
            # phone jump to catch up.
            if not await self._await_resume():
                return
            self._distance_total += covered_m
            self._current = position
            await self._location.set(*position)
            await self._emit("event.position_update")

        return await walk_segment(
            start=self._current,
            target=target,
            speed_mps=self._settings.speed_mps,
            tick_s=self.TICK_S,
            stop_event=self._stop_event,
            on_step=on_step,
        )

    async def _await_resume(self) -> bool:
        """Block while paused. False if we were stopped instead."""
        if self._resume_event.is_set():
            return not self._stop_event.is_set()
        await self._resume_event.wait()
        return not self._stop_event.is_set()

    async def _wait_after(self, step: FlowerStep) -> bool:
        if step.wait_s <= 0:
            return not self._stop_event.is_set()
        self._state = "waiting"
        self._current_speed = 0.0
        await self._emit("event.state_changed")
        completed = await sleep_or_stop(self._stop_event, step.wait_s)
        if completed and not await self._await_resume():
            return False
        if completed:
            self._state = "moving"
        return completed

    async def _emit(self, method: str) -> None:
        if self._on_event is None:
            return
        try:
            await self._on_event(method, self.status())
        except Exception:                                   # noqa: BLE001
            # An event listener that throws must not take the run with
            # it; the phone is mid-route and the user is watching it.
            log.exception("flower runner event listener failed")
