"""Flower-farmer plan geometry and arithmetic."""

from __future__ import annotations

import math

import pytest

from lociighostd.flower_plan import (
    FlowerSettings,
    estimate_seconds,
    offset_point,
    plan,
    resume_from,
    ring,
    summarise,
    with_defaults,
)
from lociighostd.interpolator import haversine_m


TAIPEI = (25.0339, 121.5645)
ARCTIC = (70.0, 20.0)


# ── Geometry ────────────────────────────────────────────────────────


def test_offset_point_lands_exactly_the_requested_distance_away():
    for bearing in (0, 45, 90, 180, 270, 359):
        p = offset_point(TAIPEI, 40.0, bearing)
        assert haversine_m(TAIPEI, p) == pytest.approx(40.0, abs=0.001)


def test_bearings_point_where_they_should():
    north = offset_point(TAIPEI, 100.0, 0)
    east = offset_point(TAIPEI, 100.0, 90)
    assert north[0] > TAIPEI[0] and north[1] == pytest.approx(TAIPEI[1], abs=1e-9)
    assert east[1] > TAIPEI[1] and east[0] == pytest.approx(TAIPEI[0], abs=1e-6)


def test_the_ring_is_round_far_from_the_equator():
    """The flat "divide by 111 km and by cos(lat)" form that the random
    walker uses for its metre-scale steps is 17 cm out on a 100 m ring
    at 70 N — visible as an out-of-round ring walked hundreds of times
    in a session. The spherical form is exact, so the tolerance here is
    tight enough to fail if anyone swaps it back.
    """
    settings = FlowerSettings(radius_m=100.0, segments=12)
    for point in ring(ARCTIC, settings):
        assert haversine_m(ARCTIC, point) == pytest.approx(100.0, abs=0.01)


def test_a_whole_lap_ends_where_it_started():
    points = ring(TAIPEI, FlowerSettings(segments=8, laps=1.0))
    assert haversine_m(points[0], points[-1]) == pytest.approx(0.0, abs=0.001)


def test_half_a_lap_ends_on_the_far_side():
    settings = FlowerSettings(radius_m=50.0, segments=8, laps=0.5)
    points = ring(TAIPEI, settings)
    assert haversine_m(points[0], points[-1]) == pytest.approx(100.0, abs=0.1)


def test_consecutive_vertices_are_one_chord_apart():
    settings = FlowerSettings(radius_m=60.0, segments=6, laps=1.0)
    points = ring(TAIPEI, settings)
    chord = 2 * 60.0 * math.sin(math.pi / 6)
    for a, b in zip(points, points[1:]):
        assert haversine_m(a, b) == pytest.approx(chord, abs=0.01)


# ── Half-lap rounding ───────────────────────────────────────────────


def test_half_laps_round_up_not_to_even():
    """Python's `round` sends halves to the nearest even number, so
    5 segments x 0.5 laps (2.5) would give 2 while 7 x 0.5 (3.5) gives
    4 — the same setting rounding in two directions because of an
    unrelated number. Both round up here.
    """
    assert round(2.5) == 2                      # the trap, pinned
    assert FlowerSettings(segments=5, laps=0.5).vertices_per_point == 3
    assert FlowerSettings(segments=7, laps=0.5).vertices_per_point == 4


def test_laps_snap_to_half_steps():
    assert FlowerSettings(laps=1.2).laps == 1.0
    assert FlowerSettings(laps=1.3).laps == 1.5
    assert FlowerSettings(laps=0.1).laps == 0.5


# ── Clamping ────────────────────────────────────────────────────────


def test_out_of_range_settings_are_clamped_not_rejected():
    s = FlowerSettings(segments=200, rounds=0, radius_m=99_999.0, speed_mps=0.0)
    assert s.segments == 20
    assert s.rounds == 1
    assert s.radius_m == 2_000.0
    assert s.speed_mps > 0
    assert FlowerSettings(segments=1).segments == 3


def test_non_finite_settings_raise():
    with pytest.raises(ValueError):
        FlowerSettings(radius_m=float("nan"))
    with pytest.raises(ValueError):
        FlowerSettings(speed_mps=float("inf"))


# ── The plan ────────────────────────────────────────────────────────


def test_plan_expands_every_round_and_every_point():
    settings = FlowerSettings(segments=4, laps=1.0, rounds=3)
    steps = plan([TAIPEI, ARCTIC], settings)
    # 1 arrival + 4 orbit vertices, per point, per round.
    assert len(steps) == 3 * 2 * 5
    assert [s.kind for s in steps[:5]] == ["travel", "orbit", "orbit", "orbit", "orbit"]
    assert {s.round_index for s in steps} == {0, 1, 2}
    assert {s.point_index for s in steps} == {0, 1}


def test_no_waypoints_is_an_empty_plan_not_an_error():
    assert plan([], FlowerSettings()) == []


def test_waits_land_on_the_right_steps():
    settings = FlowerSettings(segments=4, laps=1.0, dwell_s=2.0,
                              wait_before_s=7.0, wait_after_s=11.0)
    steps = plan([TAIPEI], settings)
    assert steps[0].wait_s == 7.0                 # before orbiting
    assert [s.wait_s for s in steps[1:4]] == [2.0, 2.0, 2.0]
    # Both apply on the last vertex: a user who set both meant both.
    assert steps[4].wait_s == 13.0


# ── The estimate ────────────────────────────────────────────────────


def test_the_estimate_is_travel_plus_orbit_plus_waits():
    settings = FlowerSettings(radius_m=100.0, segments=4, laps=1.0, speed_mps=10.0)
    steps = plan([TAIPEI], settings)
    chord = 2 * 100.0 * math.sin(math.pi / 4)
    expected = 100.0 / 10.0 + 4 * chord / 10.0
    assert estimate_seconds(steps, settings, origin=TAIPEI) == pytest.approx(
        expected, abs=0.05)


def test_teleporting_between_points_removes_only_the_travel_legs():
    walked = FlowerSettings(radius_m=30.0, segments=6, speed_mps=1.4)
    flown = FlowerSettings(radius_m=30.0, segments=6, speed_mps=1.4,
                           teleport_between=True)
    far = (25.2, 121.8)
    steps_walked = plan([TAIPEI, far], walked)
    steps_flown = plan([TAIPEI, far], flown)
    assert [(s.lat, s.lng) for s in steps_walked] == [(s.lat, s.lng) for s in steps_flown]

    orbit_only = estimate_seconds(steps_flown, flown, origin=TAIPEI)
    both = estimate_seconds(steps_walked, walked, origin=TAIPEI)
    # ~24 km between the two waypoints at walking pace is hours.
    assert both - orbit_only > 3 * 3600


def test_waits_are_counted_even_when_teleporting():
    settings = FlowerSettings(segments=3, laps=1.0, radius_m=1.0,
                              wait_before_s=5.0, dwell_s=1.0,
                              teleport_between=True, speed_mps=1000.0)
    steps = plan([TAIPEI], settings)
    assert estimate_seconds(steps, settings, origin=TAIPEI) == pytest.approx(
        5.0 + 3 * 1.0, abs=0.05)


def test_summarise_agrees_with_the_plan_it_measured():
    settings = FlowerSettings(segments=5, laps=1.5, rounds=2)
    centers = [TAIPEI, ARCTIC]
    summary = summarise(centers, settings, origin=TAIPEI)
    steps = plan(centers, settings)
    assert summary["steps"] == len(steps)
    assert summary["points"] == 2
    assert summary["rounds"] == 2
    assert summary["vertices_per_point"] == 8      # floor(5 * 1.5 + 0.5)
    assert summary["seconds"] == pytest.approx(
        estimate_seconds(steps, settings, origin=TAIPEI))


# ── Resume ──────────────────────────────────────────────────────────


def test_resume_returns_the_tail():
    steps = plan([TAIPEI], FlowerSettings(segments=4))
    assert resume_from(steps, 2) == steps[2:]
    assert resume_from(steps, 0) == steps


def test_resume_clamps_instead_of_raising():
    """The completed count comes back from a run that may have been cut
    off mid-step; an off-by-one has to end the run, not crash it."""
    steps = plan([TAIPEI], FlowerSettings(segments=4))
    assert resume_from(steps, len(steps) + 10) == []
    assert resume_from(steps, -3) == steps


# ── Params ──────────────────────────────────────────────────────────


def test_unknown_params_are_ignored():
    """An older daemon must not reject a newer app's extra keys."""
    s = with_defaults({"segments": 12, "something_from_v1_18": True})
    assert s.segments == 12
    assert s.laps == FlowerSettings().laps


def test_missing_params_fall_back_to_the_defaults():
    assert with_defaults(None) == FlowerSettings()
    assert with_defaults({"radius_m": None}).radius_m == FlowerSettings().radius_m
