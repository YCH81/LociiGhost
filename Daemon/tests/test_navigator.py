"""Navigator loop.

272 lines that drive every route the app plays, with zero test coverage
before this file: the 116 lines of test_interpolator.py all pointed at
`interpolator.interpolate()`, which production never calls (see
test_interpolator's own note). These cover the loop that actually runs.
"""
from __future__ import annotations

import asyncio

import pytest

from lociighostd.navigator import Navigator

from ._fakes import FakeLocation

pytestmark = pytest.mark.asyncio

# A short east-west leg, ~100 m apart per step at these latitudes.
A = (25.0000, 121.0000)
B = (25.0000, 121.0100)      # ~1.0 km east
C = (25.0100, 121.0100)      # ~1.1 km north


# Since the W8 fix the navigator advances by REAL elapsed time, so a
# route takes distance / speed wall-clock seconds no matter how small
# TICK_S is. Tests that need a route to finish therefore use an absurd
# speed rather than a small tick.
WARP = 50_000.0        # m/s — ~1 km leg completes in ~20 ms


@pytest.fixture(autouse=True)
def fast_ticks(monkeypatch):
    """Run the loop at 100 Hz so tests finish instantly."""
    monkeypatch.setattr(Navigator, "TICK_S", 0.01)
    monkeypatch.setattr(Navigator, "MAX_TICK_CATCHUP_S", 0.05)


async def _run_to_completion(nav: Navigator, timeout: float = 5.0) -> None:
    nav.start()
    await asyncio.wait_for(nav.wait(), timeout=timeout)


# ── Finishing ──────────────────────────────────────────────────────

async def test_route_ends_exactly_on_the_last_waypoint():
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, B], speed_mps=WARP,
                    profile="driving")
    await _run_to_completion(nav)
    assert loc.calls[0] == A, "the start point must be pushed first"
    assert loc.calls[-1] == B, "the route must end on its last waypoint"
    assert nav.state == "idle"
    assert nav.status().to_json()["progress"] == pytest.approx(1.0)


async def test_the_endpoint_is_not_pushed_twice():
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, B], speed_mps=WARP,
                    profile="driving")
    await _run_to_completion(nav)
    trailing = 0
    for call in reversed(loc.calls):
        if call != B:
            break
        trailing += 1
    assert trailing == 1, f"endpoint repeated {trailing} times"


# ── Degenerate geometry ────────────────────────────────────────────

async def test_a_repeated_waypoint_does_not_divide_by_zero():
    """[A, A, B] gives the first segment zero length. Multi-stop lap 2
    produced exactly this shape before the L6 fix, so the daemon has to
    survive it regardless."""
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, A, B], speed_mps=WARP,
                    profile="driving")
    await _run_to_completion(nav)
    assert loc.calls[-1] == B


async def test_a_zero_length_route_still_finishes():
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, A], speed_mps=WARP,
                    profile="driving")
    await _run_to_completion(nav)
    assert nav.state == "idle"
    assert nav.status().to_json()["progress"] == pytest.approx(1.0)


async def test_fewer_than_two_coords_is_rejected():
    with pytest.raises(ValueError):
        Navigator(location=FakeLocation(), coords=[A], speed_mps=1.0,
                  profile="driving")


async def test_non_positive_speed_is_rejected():
    with pytest.raises(ValueError):
        Navigator(location=FakeLocation(), coords=[A, B], speed_mps=0.0,
                  profile="driving")


# ── pause / resume / stop ──────────────────────────────────────────

async def test_stop_while_paused_terminates():
    """The pause gate parks on an asyncio.Event; stop() has to open it
    or the loop never observes the stop and wait() hangs forever."""
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, B, C], speed_mps=1.0,
                    profile="driving")
    nav.start()
    await asyncio.sleep(0.05)
    await nav.pause()
    assert nav.state == "paused"
    await asyncio.wait_for(nav.stop(), timeout=2.0)
    assert nav.state == "stopped"


async def test_resume_continues_from_where_it_paused():
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, B, C], speed_mps=50.0,
                    profile="driving")
    nav.start()
    await asyncio.sleep(0.05)
    await nav.pause()
    at_pause = len(loc.calls)
    await asyncio.sleep(0.05)
    assert len(loc.calls) == at_pause, "a paused navigator kept moving"
    await nav.resume()
    await asyncio.sleep(0.05)
    assert len(loc.calls) > at_pause
    await nav.stop()


async def test_pause_after_the_route_ended_is_a_no_op():
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, B], speed_mps=WARP,
                    profile="driving")
    await _run_to_completion(nav)
    await nav.pause()
    assert nav.state == "idle", "pausing a finished route must not fake a pause"


# ── W8: elapsed-time stepping ──────────────────────────────────────

async def test_a_slow_channel_does_not_slow_the_ground_speed():
    """Before W8 the step was a fixed speed * TICK_S while the sleep
    deadline was computed after set() returned, so a set() taking four
    ticks' worth of time advanced one tick's worth of distance — the
    iPhone crawled while the ETA quoted the nominal speed."""
    slow = FakeLocation(delay=Navigator.TICK_S * 4)
    fast = FakeLocation()
    coords = [A, B]
    results = {}
    for name, loc in (("slow", slow), ("fast", fast)):
        nav = Navigator(location=loc, coords=coords, speed_mps=WARP,
                        profile="driving")
        started = asyncio.get_running_loop().time()
        await _run_to_completion(nav)
        results[name] = asyncio.get_running_loop().time() - started

    # The slow channel can't be faster, but it must not be dramatically
    # slower either: distance covered now tracks wall-clock time.
    assert results["slow"] < results["fast"] * 6 + 1.0, results


async def test_a_pause_is_not_billed_as_travel_time():
    """The catch-up clamp plus the anchor reset must stop a resume from
    teleporting the device forward by the whole pause duration."""
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, B, C], speed_mps=20.0,
                    profile="driving")
    nav.start()
    await asyncio.sleep(0.03)
    await nav.pause()
    before = nav.status().cumulative_m
    await asyncio.sleep(0.3)          # 30 ticks' worth of wall clock
    await nav.resume()
    await asyncio.sleep(0.02)
    jumped = nav.status().cumulative_m - before
    await nav.stop()
    # One or two ticks of movement is fine; the whole pause is not.
    assert jumped < 20.0 * Navigator.MAX_TICK_CATCHUP_S * 2, jumped


# ── W9: failures are reported, not swallowed ───────────────────────

async def test_a_dead_channel_reports_failed_not_idle():
    """_run had try/finally and no except, so a raising set() killed the
    task with an unretrieved exception and a route that stopped for no
    stated reason. "failed" must also be distinct from "idle", which
    the Mac treats as natural completion and uses to start the next
    lap."""
    events: list[tuple[str, str]] = []

    async def emit(method, status):
        events.append((method, status.state))

    loc = FakeLocation(fail_after=2, exc=RuntimeError("channel gone"))
    nav = Navigator(location=loc, coords=[A, B, C], speed_mps=5.0,
                    profile="driving", on_event=emit)
    nav.start()
    await asyncio.wait_for(nav.wait(), timeout=3.0)

    assert nav.state == "failed"
    assert "channel gone" in (nav.status().error or "")
    assert ("event.state_changed", "failed") in events
    assert ("event.state_changed", "idle") not in events


# ── apply_speed ────────────────────────────────────────────────────

async def test_apply_speed_changes_the_step_size():
    loc = FakeLocation()
    nav = Navigator(location=loc, coords=[A, B, C], speed_mps=5.0,
                    profile="driving")
    nav.start()
    await asyncio.sleep(0.05)
    slow_progress = nav.status().cumulative_m
    await nav.apply_speed(500.0)
    await asyncio.sleep(0.05)
    fast_progress = nav.status().cumulative_m - slow_progress
    await nav.stop()
    assert fast_progress > slow_progress


async def test_apply_speed_rejects_non_positive():
    nav = Navigator(location=FakeLocation(), coords=[A, B],
                    speed_mps=1.0, profile="driving")
    with pytest.raises(ValueError):
        await nav.apply_speed(0.0)
