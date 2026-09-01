"""The one rule for "move toward a point at a speed".

Every mover — the random walker, the flower runner — advances the
device in fixed ticks along a straight line and stops when asked. That
loop was written once per mover, and two copies of a timing loop drift:
one rounds the final step, the other overshoots it; one checks the stop
event before the sleep, the other after, and only one of them stops
promptly. So it lives here, and the movers supply what differs — where
the position goes, and what they count.

Pure of I/O: the caller's `on_step` does the device write and whatever
bookkeeping it wants. This module only decides where the next tick is
and when to stop.
"""

from __future__ import annotations

import asyncio
from typing import Awaitable, Callable

from .interpolator import haversine_m


StepCallback = Callable[[tuple[float, float], float], Awaitable[None]]
"""Called once per tick with (new position, metres covered by this tick)."""


async def walk_segment(
    start: tuple[float, float],
    target: tuple[float, float],
    speed_mps: float,
    tick_s: float,
    stop_event: asyncio.Event,
    on_step: StepCallback,
) -> bool:
    """Advance from `start` to `target`, one tick at a time.

    Returns True on arrival, False if `stop_event` was set first. The
    final tick lands exactly on `target` rather than overshooting it,
    which matters for a flower ring: an overshoot of a few centimetres
    per vertex, times twenty vertices, times fifty laps, is a ring that
    slowly spirals.
    """
    current = start
    while not stop_event.is_set():
        remaining = haversine_m(current, target)
        step_m = speed_mps * tick_s
        if remaining <= step_m:
            await on_step(target, remaining)
            return True
        fraction = step_m / remaining
        current = (
            current[0] + (target[0] - current[0]) * fraction,
            current[1] + (target[1] - current[1]) * fraction,
        )
        await on_step(current, step_m)
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=tick_s)
            if stop_event.is_set():
                return False
        except asyncio.TimeoutError:
            pass
    return False


async def sleep_or_stop(stop_event: asyncio.Event, seconds: float) -> bool:
    """Wait `seconds`, or until asked to stop. True if the wait
    completed, False if it was cut short."""
    if seconds <= 0:
        return not stop_event.is_set()
    try:
        await asyncio.wait_for(stop_event.wait(), timeout=seconds)
        return False
    except asyncio.TimeoutError:
        return True
