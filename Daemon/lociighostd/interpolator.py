"""Generate position ticks along a polyline at a given ground speed.

Pure functions — no I/O, no async, no pymobiledevice3. The simulation
engine wires these into a real-time loop; tests here run instantly.

Why "ticks"? Each tick is the (lat, lng, elapsed, distance_so_far) the
engine should send to the iPhone at one update of its main loop. The
caller decides how often to consume them; we just do the geometry.
"""

from __future__ import annotations

import math
from collections.abc import Iterator
from dataclasses import dataclass


EARTH_RADIUS_M = 6_371_000.0


@dataclass(frozen=True, slots=True)
class Tick:
    lat: float
    lng: float
    elapsed_s: float                  # seconds since route start
    cumulative_m: float               # metres travelled along the route
    segment_index: int                # which polyline segment we're on


def normalize_latlng(lat: float, lng: float) -> tuple[float, float]:
    """Fold an arbitrary (lat, lng) back onto the globe.

    v1.15.2 audit (L12): the joystick and the random walker integrate
    small deltas with no bounds check, so holding north near the pole
    produced lat > 90 — and since the longitude scale divides by
    cos(lat), guarded only by `max(..., 1e-6)`, the very next step's
    longitude delta exploded and the iPhone shot across the map.
    Sitting at lng 179.99 and walking east produced lng > 180, which
    the DVT service accepts and renders nonsensically.

    Crossing a pole puts you on the antipodal meridian, so the
    longitude is rotated 180 degrees in that branch rather than merely
    clamped — clamping would make a walk over the pole slide sideways
    along it instead of continuing straight.
    """
    if not (math.isfinite(lat) and math.isfinite(lng)):
        raise ValueError(f"non-finite coordinate ({lat}, {lng})")
    lat = ((lat + 90.0) % 360.0) - 90.0        # -> [-90, 270)
    if lat > 90.0:
        lat = 180.0 - lat
        lng += 180.0
    lng = ((lng + 180.0) % 360.0) - 180.0
    return (lat, lng)


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Great-circle distance in metres between two (lat, lng) tuples."""
    lat1, lng1 = a
    lat2, lng2 = b
    rlat1, rlat2 = math.radians(lat1), math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    h = (
        math.sin(dlat / 2) ** 2
        + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlng / 2) ** 2
    )
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(h))


def route_length_m(coords: list[tuple[float, float]]) -> float:
    """Sum of segment lengths along the polyline."""
    total = 0.0
    for i in range(len(coords) - 1):
        total += haversine_m(coords[i], coords[i + 1])
    return total


def route_duration_s(coords: list[tuple[float, float]], speed_mps: float) -> float:
    """Total time to walk/drive the polyline at constant speed."""
    if speed_mps <= 0:
        return float("inf")
    return route_length_m(coords) / speed_mps


# `interpolate()` lived here until v1.15.2 and produced (lat, lng,
# elapsed, distance) ticks along a polyline. Production never called
# it — the real playback loop is `Navigator._advance` +
# `_current_position`, an independent implementation — and it carried
# two bugs of its own: it re-yielded the final point when the route
# length divided evenly by the step, and its `if seg_idx >= len(coords)
# - 1: break` sat inside a branch where the condition could never hold.
# All 116 lines of test_interpolator.py were aimed at it, which is to
# say the daemon's most-tested function was the one nothing ran. The
# tests that mattered moved to test_navigator.py; the ones for
# `haversine_m` / `route_length_m` (which production does use) stayed.
# (v1.15.2 audit L19.)

