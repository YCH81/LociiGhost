"""The flower runner: does it walk the plan, stop when told, resume."""

from __future__ import annotations

import asyncio

import pytest

from lociighostd.flower_plan import FlowerSettings, plan
from lociighostd.flower_runner import FlowerRunner
from lociighostd.interpolator import haversine_m

from ._fakes import FakeLocation


TAIPEI = (25.0339, 121.5645)
FAR = (25.2, 121.8)

# Fast enough that a whole ring is walked in a couple of ticks, so the
# tests run in milliseconds rather than in real walking time.
WARP = 10_000.0


def _settings(**kw) -> FlowerSettings:
    base = dict(radius_m=50.0, segments=4, laps=1.0, speed_mps=WARP)
    base.update(kw)
    return FlowerSettings(**base)


async def _run_to_completion(runner: FlowerRunner, timeout: float = 5.0) -> None:
    runner.start()
    await asyncio.wait_for(runner._task, timeout=timeout)


@pytest.mark.asyncio
async def test_it_visits_every_planned_position():
    loc = FakeLocation()
    settings = _settings()
    runner = FlowerRunner(loc, [TAIPEI], settings, start_position=TAIPEI)
    await _run_to_completion(runner)

    expected = plan([TAIPEI], settings)
    # Every planned vertex is reached exactly; the ticks in between are
    # intermediate positions, so the planned ones are a subsequence.
    for step in expected:
        assert any(
            haversine_m((step.lat, step.lng), pushed) < 0.01 for pushed in loc.calls
        ), f"never reached {step.kind} step at {step.lat}, {step.lng}"
    assert runner.status().step_index == len(expected)
    assert runner.state == "stopped"


@pytest.mark.asyncio
async def test_the_device_stays_on_the_ring():
    """The whole feature is small circles around a point. A run that
    drifts off the ring is the one failure that would look right in the
    logs and wrong on the map."""
    loc = FakeLocation()
    settings = _settings(radius_m=50.0, segments=12, laps=2.0)
    runner = FlowerRunner(loc, [TAIPEI], settings, start_position=TAIPEI)
    await _run_to_completion(runner)

    # Skip the approach: the first leg walks out to the ring.
    on_ring = loc.calls[3:]
    assert on_ring
    for point in on_ring:
        assert haversine_m(TAIPEI, point) <= 50.5


@pytest.mark.asyncio
async def test_stop_ends_the_run_promptly_and_mid_plan():
    loc = FakeLocation()
    # Slow enough that the run is nowhere near done when we stop it.
    settings = _settings(segments=20, laps=10.0, rounds=5, speed_mps=1.0)
    runner = FlowerRunner(loc, [TAIPEI], settings, start_position=TAIPEI)
    runner.start()
    await asyncio.sleep(0.05)
    await asyncio.wait_for(runner.stop(), timeout=2.0)

    assert runner.state == "stopped"
    status = runner.status()
    assert status.step_index < status.total_steps
    pushed = len(loc.calls)
    await asyncio.sleep(0.1)
    assert len(loc.calls) == pushed, "kept pushing positions after stop"


@pytest.mark.asyncio
async def test_waits_are_interruptible():
    """A ten-minute wait at a waypoint must not mean Stop takes ten
    minutes."""
    loc = FakeLocation()
    settings = _settings(wait_before_s=600.0)
    runner = FlowerRunner(loc, [TAIPEI], settings, start_position=TAIPEI)
    runner.start()
    await asyncio.sleep(0.05)
    await asyncio.wait_for(runner.stop(), timeout=1.0)
    assert runner.state == "stopped"


@pytest.mark.asyncio
async def test_resuming_skips_what_was_already_done():
    settings = _settings()
    total = len(plan([TAIPEI], settings))

    loc = FakeLocation()
    runner = FlowerRunner(loc, [TAIPEI], settings,
                          start_position=TAIPEI, completed_steps=total - 1)
    await _run_to_completion(runner)
    # One step left, and a walk takes at least one push.
    assert 0 < len(loc.calls) <= 3
    assert runner.status().step_index == total


@pytest.mark.asyncio
async def test_teleporting_between_waypoints_does_not_walk_the_hop():
    loc = FakeLocation()
    settings = _settings(teleport_between=True)
    runner = FlowerRunner(loc, [TAIPEI, FAR], settings, start_position=TAIPEI)
    await _run_to_completion(runner)

    assert any(haversine_m(FAR, p) < 51 for p in loc.calls), "never reached the far ring"
    # Two rings of 4 x ~71 m is under 600 m. The 24 km between the
    # waypoints must not be in the counter: the phone didn't walk it.
    assert haversine_m(TAIPEI, FAR) > 20_000
    assert runner.status().distance_traveled_m < 1_000


@pytest.mark.asyncio
async def test_the_eta_counts_down_as_steps_complete():
    loc = FakeLocation()
    settings = _settings(segments=8, laps=1.0, rounds=2)
    runner = FlowerRunner(loc, [TAIPEI], settings, start_position=TAIPEI)
    before = runner.status().eta_seconds
    await _run_to_completion(runner)
    after = runner.status().eta_seconds
    assert before > 0
    assert after == pytest.approx(0.0, abs=0.001)


@pytest.mark.asyncio
async def test_the_drawn_path_stops_at_the_next_waypoint():
    """Drawing the whole run would put a straight line across the city
    through every ring."""
    loc = FakeLocation()
    settings = _settings(segments=4, laps=1.0)
    runner = FlowerRunner(loc, [TAIPEI, FAR], settings, start_position=TAIPEI)
    path = runner.status().planned_path
    for point in path:
        assert haversine_m(FAR, point) > 1_000


@pytest.mark.asyncio
async def test_an_event_listener_that_throws_does_not_kill_the_run():
    async def broken(method, status):
        raise RuntimeError("listener exploded")

    loc = FakeLocation()
    settings = _settings()
    runner = FlowerRunner(loc, [TAIPEI], settings,
                          on_event=broken, start_position=TAIPEI)
    await _run_to_completion(runner)
    assert runner.status().step_index == len(plan([TAIPEI], settings))


def test_a_run_needs_a_waypoint():
    with pytest.raises(ValueError):
        FlowerRunner(FakeLocation(), [], _settings())


# ----------------------------------------------------------------------
# Pause / resume. The runner used to have neither, so the toolbar's
# pause button raised "No active navigation" during an orbit.
# ----------------------------------------------------------------------


# The runner ticks once a second, and a segment short enough to finish
# inside one tick never sleeps at all. So a pause test has to pick a
# speed that needs several ticks per segment, and then wait longer than
# a tick to prove nothing moved.
SLOW = 10.0
TICK_AND_A_BIT = 1.3


@pytest.mark.asyncio
async def test_pause_holds_position_and_resume_carries_on():
    loc = FakeLocation()
    runner = FlowerRunner(loc, [TAIPEI], _settings(speed_mps=SLOW, segments=20),
                          start_position=TAIPEI)
    runner.start()
    await asyncio.sleep(0.05)

    assert await runner.pause() is True
    assert runner.state == "paused"

    settled = len(loc.calls)
    await asyncio.sleep(TICK_AND_A_BIT)
    assert len(loc.calls) == settled, "the phone kept moving while paused"

    assert await runner.resume() is True
    assert runner.state == "moving"
    await asyncio.sleep(TICK_AND_A_BIT)
    assert len(loc.calls) > settled, "the run did not carry on after resume"

    await runner.stop()


@pytest.mark.asyncio
async def test_pause_and_resume_report_whether_they_applied():
    """A pause that lands on a run which is not moving must say so,
    rather than leaving the Mac rendering 'paused' over nothing."""
    loc = FakeLocation()
    runner = FlowerRunner(loc, [TAIPEI], _settings(speed_mps=1.0, segments=20),
                          start_position=TAIPEI)

    # Nothing started yet.
    assert await runner.pause() is False
    assert await runner.resume() is False

    runner.start()
    await asyncio.sleep(0.05)
    assert await runner.pause() is True
    # Already paused — a second press is not a second pause.
    assert await runner.pause() is False
    assert await runner.resume() is True
    assert await runner.resume() is False

    await runner.stop()


@pytest.mark.asyncio
async def test_stop_while_paused_actually_stops():
    """The regression this pairs with: the loop waits on the resume
    gate, so a stop that only sets the stop flag would leave the task
    parked there forever and `stop()` awaiting it."""
    loc = FakeLocation()
    runner = FlowerRunner(loc, [TAIPEI], _settings(speed_mps=1.0, segments=20),
                          start_position=TAIPEI)
    runner.start()
    await asyncio.sleep(0.05)
    assert await runner.pause() is True

    await asyncio.wait_for(runner.stop(), timeout=2.0)
    assert runner.state == "stopped"
