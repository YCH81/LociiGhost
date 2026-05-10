"""Pure-math tests for the interpolator. No I/O, no asyncio."""

from __future__ import annotations

import math

import pytest

from locwarpd.interpolator import (
    Tick,
    haversine_m,
    interpolate,
    route_duration_s,
    route_length_m,
)


# ----------------------------------------------------------------------
# haversine
# ----------------------------------------------------------------------

def test_haversine_zero():
    assert haversine_m((25.0, 121.0), (25.0, 121.0)) == 0.0


def test_haversine_known_distance():
    # Taipei 101 → Taipei Main Station, ~5.5 km as the crow flies.
    d = haversine_m((25.0330, 121.5645), (25.0478, 121.5170))
    assert 4_900 < d < 5_400


def test_haversine_symmetry():
    a = (51.5074, -0.1278)         # London
    b = (40.7128, -74.0060)        # New York
    assert haversine_m(a, b) == pytest.approx(haversine_m(b, a))


# ----------------------------------------------------------------------
# route_length / route_duration
# ----------------------------------------------------------------------

def test_route_length_three_points():
    coords = [(25.0, 121.0), (25.001, 121.0), (25.002, 121.0)]
    expected = haversine_m(coords[0], coords[1]) + haversine_m(coords[1], coords[2])
    assert route_length_m(coords) == pytest.approx(expected)


def test_route_duration():
    coords = [(25.0, 121.0), (25.01, 121.0)]   # ~1.1 km
    speed = 11.1                                # ~40 km/h
    expected = haversine_m(*coords) / speed
    assert route_duration_s(coords, speed) == pytest.approx(expected)


def test_route_duration_zero_speed():
    coords = [(25.0, 121.0), (25.01, 121.0)]
    assert math.isinf(route_duration_s(coords, 0))


# ----------------------------------------------------------------------
# interpolate
# ----------------------------------------------------------------------

def test_interpolate_yields_first_point_first():
    coords = [(0.0, 0.0), (0.001, 0.0)]
    ticks = list(interpolate(coords, speed_mps=1.0, tick_s=1.0))
    assert ticks[0].lat == 0.0 and ticks[0].lng == 0.0
    assert ticks[0].elapsed_s == 0.0
    assert ticks[0].cumulative_m == 0.0


def test_interpolate_yields_last_point_last():
    coords = [(0.0, 0.0), (0.001, 0.0)]
    ticks = list(interpolate(coords, speed_mps=1.0, tick_s=1.0))
    assert ticks[-1].lat == pytest.approx(0.001)
    assert ticks[-1].lng == 0.0


def test_interpolate_total_time_matches_route_duration():
    coords = [(0.0, 0.0), (0.001, 0.0), (0.001, 0.001)]
    speed = 0.5
    expected = route_duration_s(coords, speed)
    ticks = list(interpolate(coords, speed_mps=speed, tick_s=0.5))
    assert ticks[-1].elapsed_s == pytest.approx(expected, rel=1e-3)


def test_interpolate_total_distance_matches_route_length():
    coords = [(25.0, 121.0), (25.001, 121.0), (25.001, 121.001)]
    expected = route_length_m(coords)
    ticks = list(interpolate(coords, speed_mps=1.0, tick_s=0.5))
    assert ticks[-1].cumulative_m == pytest.approx(expected, rel=1e-3)


def test_interpolate_invalid_speed_raises():
    with pytest.raises(ValueError):
        next(interpolate([(0.0, 0.0), (0.001, 0.0)], speed_mps=0))


def test_interpolate_invalid_tick_raises():
    with pytest.raises(ValueError):
        next(interpolate([(0.0, 0.0), (0.001, 0.0)], speed_mps=1.0, tick_s=0))


def test_interpolate_single_point():
    ticks = list(interpolate([(25.0, 121.0)], speed_mps=1.0))
    assert len(ticks) == 1
    assert ticks[0].lat == 25.0


def test_interpolate_monotonic_progress():
    """Each successive tick must be at least as far along as the last."""
    coords = [(0.0, 0.0), (0.005, 0.0), (0.005, 0.005), (0.01, 0.005)]
    ticks = list(interpolate(coords, speed_mps=2.0, tick_s=0.5))
    for i in range(1, len(ticks)):
        assert ticks[i].cumulative_m >= ticks[i - 1].cumulative_m
        assert ticks[i].elapsed_s >= ticks[i - 1].elapsed_s
