"""Cooldown gate: refuse a jump that no physical body could have made.

This is a plausibility rule the user configures, not a model of any
particular service's detection. It knows two things: how far the last
position was from the next one, and how long ago that was. From those
it computes the earliest moment the next position may be sent, and the
caller either waits or is told how long is left.

Deliberately not "what does game X allow". The parameters are the
user's — a maximum speed they consider reasonable, an optional floor
under every jump, and optional distance/wait rows if they'd rather
spell it out — and the defaults are turned off, so nothing here
changes behaviour until someone asks for it.

Pure: every function takes the clock as an argument.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

from .interpolator import haversine_m


KMH_TO_MPS = 1000.0 / 3600.0


@dataclass(frozen=True, slots=True)
class CooldownStep:
    """One user-written row: "a jump of at least this far needs at
    least this long"."""

    distance_km: float
    wait_minutes: float

    def __post_init__(self) -> None:
        if not (math.isfinite(self.distance_km) and math.isfinite(self.wait_minutes)):
            raise ValueError("cooldown rows must be finite numbers")
        object.__setattr__(self, "distance_km", max(0.0, float(self.distance_km)))
        object.__setattr__(self, "wait_minutes", max(0.0, float(self.wait_minutes)))


@dataclass(frozen=True, slots=True)
class CooldownPolicy:
    enabled: bool = False
    """Off by default. A gate that silently delays teleports is the
    kind of thing a user must switch on knowingly, or the app looks
    broken."""

    max_speed_kmh: float = 0.0
    """Fastest movement considered plausible between two positions.
    0 disables the speed rule (leaving the floor and any rows)."""

    minimum_gap_s: float = 0.0
    """Floor under every jump, however short. Covers the case the speed
    rule can't: two positions a metre apart, a hundred times a second."""

    steps: tuple[CooldownStep, ...] = ()
    """Optional explicit rows. The longest matching row wins, and it is
    combined with the speed rule by taking whichever is longer — a rule
    the user wrote is a minimum, never a discount."""

    def __post_init__(self) -> None:
        for name in ("max_speed_kmh", "minimum_gap_s"):
            if not math.isfinite(getattr(self, name)):
                raise ValueError(f"{name} must be a finite number")
        object.__setattr__(self, "max_speed_kmh", max(0.0, float(self.max_speed_kmh)))
        object.__setattr__(self, "minimum_gap_s", max(0.0, float(self.minimum_gap_s)))
        object.__setattr__(
            self, "steps",
            tuple(sorted(self.steps, key=lambda s: s.distance_km)),
        )

    def required_wait_s(self, distance_m: float) -> float:
        """How long must pass between two positions `distance_m` apart."""
        if not self.enabled:
            return 0.0
        if not math.isfinite(distance_m) or distance_m < 0:
            raise ValueError(f"distance must be a finite, non-negative number: {distance_m!r}")

        required = self.minimum_gap_s
        if self.max_speed_kmh > 0:
            required = max(required, distance_m / (self.max_speed_kmh * KMH_TO_MPS))
        for step in self.steps:                     # sorted ascending
            if distance_m >= step.distance_km * 1000.0:
                required = max(required, step.wait_minutes * 60.0)
        return required


@dataclass(frozen=True, slots=True)
class CooldownVerdict:
    allowed: bool
    remaining_s: float
    required_s: float
    distance_m: float


def check(
    policy: CooldownPolicy,
    last: tuple[float, float] | None,
    last_at: float | None,
    target: tuple[float, float],
    now: float,
) -> CooldownVerdict:
    """Whether `target` may be sent at `now`.

    The first position of a session has nothing to be implausible
    relative to, so `last is None` always passes — a cooldown that
    blocked the first teleport after launch would be indistinguishable
    from the app being broken.

    A clock that went backwards (sleep, an NTP correction) is treated
    as "no time has passed" rather than as a negative wait, which would
    otherwise hand out free jumps.
    """
    if last is None or last_at is None or not policy.enabled:
        return CooldownVerdict(True, 0.0, 0.0, 0.0)

    distance = haversine_m(last, target)
    required = policy.required_wait_s(distance)
    elapsed = max(0.0, now - last_at)
    remaining = max(0.0, required - elapsed)
    return CooldownVerdict(remaining <= 0.0, remaining, required, distance)


def from_params(raw: dict | None) -> CooldownPolicy:
    """Build a policy from JSON-RPC params, ignoring unknown keys."""
    raw = raw or {}
    rows = raw.get("steps") or ()
    steps = tuple(
        CooldownStep(
            distance_km=float(row.get("distance_km", 0.0)),
            wait_minutes=float(row.get("wait_minutes", 0.0)),
        )
        for row in rows
        if isinstance(row, dict)
    )
    known = {
        field: raw[field]
        for field in ("enabled", "max_speed_kmh", "minimum_gap_s")
        if field in raw and raw[field] is not None
    }
    return replace(CooldownPolicy(steps=steps), **known)
