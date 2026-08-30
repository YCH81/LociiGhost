"""Coordinate normalisation.

v1.15.2 audit (L12): the joystick and the random walker integrate small
deltas with no bounds check. Holding north near a pole produced
lat > 90, and because the longitude scale divides by cos(lat) — guarded
only by max(..., 1e-6) — the very next step's longitude delta exploded
and the iPhone shot across the map. Sitting at lng 179.99 and walking
east produced lng > 180, which the DVT service accepts and renders
nonsensically.
"""
from __future__ import annotations

import math

import pytest

from lociighostd.interpolator import normalize_latlng


def test_ordinary_coordinates_are_untouched():
    for lat, lng in [(0.0, 0.0), (25.03, 121.56), (-33.87, 151.21),
                     (90.0, 0.0), (-90.0, 0.0), (0.0, 180.0)]:
        out = normalize_latlng(lat, lng)
        # 180 is the one value that legitimately wraps to -180.
        expected = (lat, -180.0 if lng == 180.0 else lng)
        assert out == pytest.approx(expected)


@pytest.mark.parametrize("lng_in, lng_out", [
    (180.0003, -179.9997),
    (181.0, -179.0),
    (-180.5, 179.5),
    (540.0, -180.0),
    (-360.0, 0.0),
])
def test_longitude_wraps_at_the_date_line(lng_in, lng_out):
    lat, lng = normalize_latlng(25.0, lng_in)
    assert lat == pytest.approx(25.0)
    assert lng == pytest.approx(lng_out)


@pytest.mark.parametrize("lat_in, lat_out", [
    (95.0, 85.0),
    (90.5, 89.5),
    (-95.0, -85.0),
    (-90.5, -89.5),
])
def test_crossing_a_pole_folds_the_latitude(lat_in, lat_out):
    lat, _ = normalize_latlng(lat_in, 0.0)
    assert lat == pytest.approx(lat_out)


def test_crossing_a_pole_flips_the_meridian():
    """Walking north over the pole continues down the far side, not
    sideways along it — clamping would have produced the latter."""
    lat, lng = normalize_latlng(95.0, 30.0)
    assert lat == pytest.approx(85.0)
    assert lng == pytest.approx(-150.0)


def test_output_is_always_in_range():
    for lat in [-400.0, -181.0, -90.0, 0.0, 89.9, 90.0, 123.4, 271.0, 400.0]:
        for lng in [-540.0, -181.0, -180.0, 0.0, 179.9, 180.0, 361.0]:
            out_lat, out_lng = normalize_latlng(lat, lng)
            assert -90.0 <= out_lat <= 90.0, (lat, lng, out_lat)
            assert -180.0 <= out_lng < 180.0 + 1e-9, (lat, lng, out_lng)


@pytest.mark.parametrize("bad", [math.inf, -math.inf, math.nan])
def test_non_finite_input_raises(bad):
    """Better a loud ValueError at the source than a NaN that quietly
    makes the navigator's segment length NaN and hangs the route."""
    with pytest.raises(ValueError):
        normalize_latlng(bad, 0.0)
    with pytest.raises(ValueError):
        normalize_latlng(0.0, bad)


def test_the_joystick_step_stays_on_the_globe():
    """The concrete failure: hold north at 89.99 and the old code
    walked straight off the top."""
    from lociighostd.joystick import JoystickController
    pos = (89.99, 30.0)
    for _ in range(50):
        pos = JoystickController._step(pos, 0.0, 500.0)   # due north, 500 m
        assert -90.0 <= pos[0] <= 90.0, pos
        assert -180.0 <= pos[1] <= 180.0, pos
