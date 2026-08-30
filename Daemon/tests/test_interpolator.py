"""Pure-math tests for the interpolator. No I/O, no asyncio.

Note: the `interpolate()` tests that used to make up most of this
file were removed in v1.15.2 — see the note in interpolator.py. The
playback loop they were standing in for is covered by
test_navigator.py.
"""

from __future__ import annotations

import math

import pytest

from lociighostd.interpolator import (
    haversine_m,
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
