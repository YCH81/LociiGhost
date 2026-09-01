"""Flower-farmer mode: orbit each waypoint, lap after lap.

The pattern comes from how location-based games spawn things around a
fixed point: standing still gets you one spawn, while small circles
around the point keep re-triggering the region the game watches. So the
route is not "go from A to B" but "walk a ring around A, then a ring
around B, then do the whole set again".

Pure geometry and arithmetic — no I/O, no async, no device. The runner
consumes the plan; this module decides what the plan *is*, which is the
part that has to agree exactly with the total the settings panel shows.
One generator feeding both is why the estimate can't drift from what
actually runs.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

from .interpolator import haversine_m, normalize_latlng


EARTH_RADIUS_M = 6_371_000.0

MIN_SEGMENTS = 3
MAX_SEGMENTS = 20
MIN_LAPS = 0.5
MAX_LAPS = 50.0
MAX_ROUNDS = 999
MIN_RADIUS_M = 1.0
MAX_RADIUS_M = 2_000.0


@dataclass(frozen=True, slots=True)
class FlowerSettings:
    """Everything the user can set for one flower run.

    Values are clamped on construction rather than validated with an
    exception: these arrive from a JSON-RPC call whose caller is our
    own UI, and a run that quietly uses 20 segments instead of 200 is
    a better outcome for the person than an error dialog mid-session.
    Anything genuinely nonsensical (NaN, a negative radius) is what
    `ValueError` is for.
    """

    radius_m: float = 40.0
    """Distance from the waypoint to the ring the device walks."""

    segments: int = 8
    """Vertices per full lap. 3 is a triangle; 20 is nearly a circle."""

    laps: float = 1.0
    """Laps per waypoint. Half steps are allowed — half a lap leaves
    the device on the far side of the ring, which is often exactly
    where the next waypoint is."""

    rounds: int = 1
    """How many times to walk the whole waypoint list."""

    wait_before_s: float = 0.0
    """Pause on arrival at a waypoint's ring, before orbiting."""

    wait_after_s: float = 0.0
    """Pause after the last vertex of a waypoint, before moving on."""

    dwell_s: float = 0.0
    """Pause at every vertex of the ring."""

    speed_mps: float = 1.4
    """Ground speed for everything that isn't teleported."""

    teleport_between: bool = False
    """Jump between waypoints instead of walking. The orbit itself is
    always walked — a ring of teleports is the one thing that looks
    nothing like a person."""

    def __post_init__(self) -> None:
        for name in ("radius_m", "laps", "wait_before_s", "wait_after_s",
                     "dwell_s", "speed_mps"):
            value = getattr(self, name)
            if not math.isfinite(value):
                raise ValueError(f"{name} must be a finite number, got {value!r}")

        object.__setattr__(self, "radius_m",
                           _clamp(float(self.radius_m), MIN_RADIUS_M, MAX_RADIUS_M))
        object.__setattr__(self, "segments",
                           int(_clamp(int(self.segments), MIN_SEGMENTS, MAX_SEGMENTS)))
        # Half-lap granularity: the UI's stepper moves in 0.5s, and a
        # value between the notches would silently round somewhere the
        # user can't see.
        laps = round(float(self.laps) * 2.0) / 2.0
        object.__setattr__(self, "laps", _clamp(laps, MIN_LAPS, MAX_LAPS))
        object.__setattr__(self, "rounds", int(_clamp(int(self.rounds), 1, MAX_ROUNDS)))
        object.__setattr__(self, "wait_before_s", max(0.0, float(self.wait_before_s)))
        object.__setattr__(self, "wait_after_s", max(0.0, float(self.wait_after_s)))
        object.__setattr__(self, "dwell_s", max(0.0, float(self.dwell_s)))
        object.__setattr__(self, "speed_mps", max(0.1, float(self.speed_mps)))

    @property
    def vertices_per_point(self) -> int:
        """Orbit vertices walked at one waypoint, excluding the arrival
        vertex.

        `floor(x + 0.5)` rather than `round`: Python rounds halves to
        even, so 5 segments at half a lap (2.5) would give 2 while 7
        segments at half a lap (3.5) gives 4 — the same setting
        rounding in two directions depending on an unrelated number.
        """
        return int(math.floor(self.segments * self.laps + 0.5))


@dataclass(frozen=True, slots=True)
class FlowerStep:
    """One position the runner should take the device to."""

    lat: float
    lng: float
    kind: str
    """`"travel"` for the hop onto a waypoint's ring (walked, or
    teleported when `teleport_between` is set), `"orbit"` for a vertex
    of the ring itself."""

    wait_s: float
    """Pause after arriving here."""

    point_index: int
    """Index into the caller's waypoint list."""

    round_index: int
    """0-based round, so a resumed run can report "round 3 of 5"."""


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def offset_point(
    center: tuple[float, float],
    radius_m: float,
    bearing_deg: float,
) -> tuple[float, float]:
    """The point `radius_m` from `center` along `bearing_deg`.

    Spherical, not the flat "divide by 111 km and by cos(lat)"
    approximation the walker uses for its small steps: a ring is walked
    hundreds of times in a session, and a ring that isn't round — which
    is what the flat form gives above 60° latitude — would be a
    recognisable signature.
    """
    lat1 = math.radians(center[0])
    lng1 = math.radians(center[1])
    theta = math.radians(bearing_deg)
    delta = radius_m / EARTH_RADIUS_M

    lat2 = math.asin(
        math.sin(lat1) * math.cos(delta)
        + math.cos(lat1) * math.sin(delta) * math.cos(theta)
    )
    lng2 = lng1 + math.atan2(
        math.sin(theta) * math.sin(delta) * math.cos(lat1),
        math.cos(delta) - math.sin(lat1) * math.sin(lat2),
    )
    return normalize_latlng(math.degrees(lat2), math.degrees(lng2))


def ring(
    center: tuple[float, float],
    settings: FlowerSettings,
    start_bearing_deg: float = 0.0,
) -> list[tuple[float, float]]:
    """Every position for one waypoint: the arrival vertex first, then
    one per orbit step. A whole number of laps ends where it started.
    """
    step_deg = 360.0 / settings.segments
    count = settings.vertices_per_point
    return [
        offset_point(center, settings.radius_m, start_bearing_deg + step_deg * i)
        for i in range(count + 1)
    ]


def plan(
    centers: list[tuple[float, float]],
    settings: FlowerSettings,
) -> list[FlowerStep]:
    """The whole run, expanded.

    Deterministic in (centers, settings), which is what makes resume
    cheap: a run's progress is one index into this list, so
    reconnecting after a dropped tunnel means re-planning and skipping
    ahead rather than persisting a partial route.
    """
    steps: list[FlowerStep] = []
    if not centers:
        return steps

    for round_index in range(settings.rounds):
        for point_index, center in enumerate(centers):
            points = ring(center, settings)
            steps.append(FlowerStep(
                lat=points[0][0], lng=points[0][1],
                kind="travel",
                wait_s=settings.wait_before_s,
                point_index=point_index,
                round_index=round_index,
            ))
            for i, (lat, lng) in enumerate(points[1:], start=1):
                last = i == len(points) - 1
                steps.append(FlowerStep(
                    lat=lat, lng=lng,
                    kind="orbit",
                    # The pause after the final vertex is the "leaving
                    # this waypoint" wait; the others are the per-vertex
                    # dwell. They add up when both are set, because a
                    # user who set both meant both.
                    wait_s=settings.dwell_s + (settings.wait_after_s if last else 0.0),
                    point_index=point_index,
                    round_index=round_index,
                ))
    return steps


def estimate_seconds(
    steps: list[FlowerStep],
    settings: FlowerSettings,
    origin: tuple[float, float] | None = None,
) -> float:
    """How long the plan will take, in seconds.

    Walks the same list the runner walks, so the number under the
    settings panel and the run itself can't disagree — the earlier
    multi-stop ETA drifted precisely because it re-derived the route
    from the settings instead of from the plan.
    """
    total = 0.0
    previous = origin
    for step in steps:
        here = (step.lat, step.lng)
        if previous is not None:
            teleported = step.kind == "travel" and settings.teleport_between
            if not teleported:
                total += haversine_m(previous, here) / settings.speed_mps
        total += step.wait_s
        previous = here
    return total


def summarise(
    centers: list[tuple[float, float]],
    settings: FlowerSettings,
    origin: tuple[float, float] | None = None,
) -> dict[str, float | int]:
    """Plan-and-measure, for the settings panel's live readout."""
    steps = plan(centers, settings)
    return {
        "steps": len(steps),
        "vertices_per_point": settings.vertices_per_point,
        "points": len(centers),
        "rounds": settings.rounds,
        "seconds": estimate_seconds(steps, settings, origin),
    }


def resume_from(steps: list[FlowerStep], completed: int) -> list[FlowerStep]:
    """The tail of a plan after `completed` steps.

    Clamped rather than raising: the count comes back from a run that
    may have been interrupted mid-step, and a resume that restarts the
    last vertex is right, while one that crashes on an off-by-one is
    not.
    """
    return steps[max(0, min(completed, len(steps))):]


def with_defaults(raw: dict | None) -> FlowerSettings:
    """Build settings from a JSON-RPC params dict, ignoring keys we
    don't know so an older daemon doesn't reject a newer app's call."""
    raw = raw or {}
    base = FlowerSettings()
    known = {
        field: raw[field]
        for field in (
            "radius_m", "segments", "laps", "rounds", "wait_before_s",
            "wait_after_s", "dwell_s", "speed_mps", "teleport_between",
        )
        if field in raw and raw[field] is not None
    }
    return replace(base, **known)
