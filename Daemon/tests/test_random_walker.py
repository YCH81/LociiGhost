"""Bounded random walk: the walk has to stay inside the circle.

The bug this file exists for: `_pick_target` samples inside the disc,
so straight-line mode is correct by construction -- both endpoints are
inside a convex region, and interpolating between them can't leave it.
Map mode is a different animal. The route BETWEEN two inside points is
a real road, and roads bulge: a target 200 m away across a river can
route half a kilometre out and back. Nothing re-checked the polyline,
so the iPhone visibly left the circle the user drew.

Which makes the interesting tests the ones that use a routing engine
that deliberately misbehaves.
"""
from __future__ import annotations

import asyncio
import math

import pytest

from lociighostd.random_walker import (
    RandomWalker,
    boundary_point,
    clip_polyline_to_disc,
)
from lociighostd.interpolator import haversine_m
from lociighostd.routing import Route

from ._fakes import FakeLocation

CENTER = (25.0330, 121.5654)     # Taipei 101-ish
RADIUS = 300.0


def _offset(center: tuple[float, float], north_m: float, east_m: float):
    """A coordinate `north_m` / `east_m` from `center`."""
    dlat = north_m / 111_000.0
    dlng = east_m / (111_000.0 * math.cos(math.radians(center[0])))
    return (center[0] + dlat, center[1] + dlng)


# ── clip_polyline_to_disc ────────────────────────────────────────────

def test_all_inside_is_passed_through_unchanged():
    pts = [_offset(CENTER, 50, 0), _offset(CENTER, 100, 50), _offset(CENTER, 0, 200)]
    out = clip_polyline_to_disc(CENTER, pts, CENTER, RADIUS)
    assert out == pts


def test_truncates_at_the_first_point_outside():
    inside_a = _offset(CENTER, 100, 0)
    inside_b = _offset(CENTER, 200, 0)
    outside = _offset(CENTER, 900, 0)          # way past the 300 m edge
    after = _offset(CENTER, 950, 0)            # never reached
    out = clip_polyline_to_disc(CENTER, [inside_a, inside_b, outside, after],
                                CENTER, RADIUS)
    assert out[:2] == [inside_a, inside_b]
    assert len(out) == 3, "expected the two inside points plus a boundary point"
    assert after not in out


def test_the_appended_point_sits_on_the_boundary_and_inside_it():
    inside = _offset(CENTER, 100, 0)
    outside = _offset(CENTER, 900, 0)
    out = clip_polyline_to_disc(CENTER, [inside, outside], CENTER, RADIUS)
    edge = out[-1]
    d = haversine_m(edge, CENTER)
    # On the circle...
    assert abs(d - RADIUS) < 0.5
    # ...and on the inside of it. A boundary point that lands a
    # millimetre outside would defeat the entire point of the clip,
    # because the next containment check would reject where we just
    # walked to.
    assert d <= RADIUS


def test_first_point_already_outside_still_walks_to_the_edge():
    # Origin is inside, the route's very first node is outside: the
    # walker should still get to the boundary rather than being handed
    # an empty leg.
    origin = CENTER
    outside = _offset(CENTER, 900, 0)
    out = clip_polyline_to_disc(origin, [outside], CENTER, RADIUS)
    assert len(out) == 1
    assert abs(haversine_m(out[0], CENTER) - RADIUS) < 0.5


def test_a_sub_metre_crossing_yields_no_point_at_all():
    # Already sitting on the edge: the crossing is centimetres away and
    # not worth a tick of its own.
    on_edge = _offset(CENTER, RADIUS - 0.2, 0)
    outside = _offset(CENTER, RADIUS + 50, 0)
    out = clip_polyline_to_disc(on_edge, [outside], CENTER, RADIUS)
    assert out == []


def test_origin_outside_the_disc_gives_up():
    out = clip_polyline_to_disc(_offset(CENTER, 900, 0),
                                [_offset(CENTER, 10, 0)], CENTER, RADIUS)
    assert out == []


def test_boundary_point_is_monotonic_in_the_segment():
    inside = _offset(CENTER, 10, 0)
    outside = _offset(CENTER, 5000, 0)
    edge = boundary_point(inside, outside, CENTER, RADIUS)
    # Between the two endpoints, not past either.
    assert haversine_m(inside, edge) < haversine_m(inside, outside)
    assert haversine_m(edge, CENTER) <= RADIUS


# ── the walker itself, in map mode ───────────────────────────────────

class BulgingOsrm:
    """A routing engine that always detours outside the disc.

    This is not a strawman: it is what a real road network does when
    the direct line crosses a river, a rail cutting or a park. The
    walker asked for a point inside the circle and OSRM honestly
    answers "sure, but you go around".

    The detour sits 450 m out of a 300 m disc — far enough outside to
    be unambiguous, close enough that the walker reaches it in one
    tick at the test speed. That combination matters: the first
    version of this test used a 1.2 km bulge and a walking-pace speed,
    so in three seconds the walker only ever got 130 m from the centre
    and the test passed with the fix REMOVED. A containment test that
    never reaches the boundary is not a test.
    """

    def __init__(self, center, bulge_m: float = 450.0) -> None:
        self.center = center
        self.bulge_m = bulge_m
        self.calls = 0

    async def route(self, *, from_lat, from_lng, to_lat, to_lng, profile="walking"):
        self.calls += 1
        detour = _offset(self.center, self.bulge_m, 0.0)
        return Route(
            coordinates=[(from_lat, from_lng), detour, (to_lat, to_lng)],
            distance_m=self.bulge_m * 3,
            duration_s=60.0,
            profile=profile,
        )


# One tick covers 500 m, so the 450 m detour is reached immediately and
# the disc boundary is genuinely exercised. The near-zero dwell keeps
# the walker planning legs instead of sitting still for the random
# 1.5-4 s pause, which would otherwise eat most of a short test.
WARP_SPEED = 500.0
NO_DWELL = 0.01


async def _walk_briefly(walker: RandomWalker, seconds: float = 3.0) -> None:
    walker.start()
    await asyncio.sleep(seconds)
    await walker.stop()


@pytest.mark.asyncio
async def test_map_mode_never_leaves_the_disc():
    loc = FakeLocation()
    walker = RandomWalker(
        location=loc,
        center=CENTER,
        radius_m=RADIUS,
        min_speed_mps=WARP_SPEED,
        max_speed_mps=WARP_SPEED,
        dwell_seconds_override=NO_DWELL,
        osrm=BulgingOsrm(CENTER),
        routing_engine="map",
        profile="walking",
    )
    await _walk_briefly(walker)

    assert loc.calls, "the walker never moved"
    worst = max(haversine_m(p, CENTER) for p in loc.calls)
    assert worst <= RADIUS + 1.0, (
        f"walked {worst:.1f} m from centre, {worst - RADIUS:.1f} m outside "
        f"the {RADIUS:.0f} m disc"
    )


@pytest.mark.asyncio
async def test_straight_mode_never_leaves_the_disc():
    loc = FakeLocation()
    walker = RandomWalker(
        location=loc,
        center=CENTER,
        radius_m=RADIUS,
        min_speed_mps=WARP_SPEED,
        max_speed_mps=WARP_SPEED,
        dwell_seconds_override=NO_DWELL,
        routing_engine="straight",
    )
    await _walk_briefly(walker)

    assert loc.calls
    worst = max(haversine_m(p, CENTER) for p in loc.calls)
    assert worst <= RADIUS + 1.0


@pytest.mark.asyncio
async def test_a_well_behaved_route_is_still_followed():
    """The clip must not quietly turn map mode into straight mode."""

    class TameOsrm:
        def __init__(self):
            self.calls = 0

        async def route(self, *, from_lat, from_lng, to_lat, to_lng, profile="walking"):
            self.calls += 1
            # A gentle dog-leg that stays well inside the disc.
            mid = _offset(CENTER, 60, 60)
            return Route(
                coordinates=[(from_lat, from_lng), mid, (to_lat, to_lng)],
                distance_m=200.0, duration_s=60.0, profile=profile,
            )

    osrm = TameOsrm()
    loc = FakeLocation()
    walker = RandomWalker(
        location=loc, center=CENTER, radius_m=RADIUS,
        min_speed_mps=WARP_SPEED, max_speed_mps=WARP_SPEED,
        dwell_seconds_override=NO_DWELL,
        osrm=osrm, routing_engine="map", profile="walking",
    )
    await _walk_briefly(walker)

    assert osrm.calls > 0, "map mode stopped calling the router"
    assert max(haversine_m(p, CENTER) for p in loc.calls) <= RADIUS + 1.0
