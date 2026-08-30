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


def interpolate(
    coords: list[tuple[float, float]],
    speed_mps: float,
    tick_s: float = 1.0,
) -> Iterator[Tick]:
    """Yield ticks every `tick_s` seconds at constant `speed_mps` along
    the polyline `coords`. The final yielded tick is always exactly the
    last polyline point so callers always end at the destination.

    Raises ValueError on invalid input.
    """
    if speed_mps <= 0:
        raise ValueError("speed_mps must be > 0")
    if tick_s <= 0:
        raise ValueError("tick_s must be > 0")
    if len(coords) < 2:
        # Degenerate route — yield the only point, nothing to move along.
        if coords:
            yield Tick(coords[0][0], coords[0][1], 0.0, 0.0, 0)
        return

    elapsed = 0.0
    cumulative = 0.0
    step_m = speed_mps * tick_s

    # First tick: starting point at t=0.
    yield Tick(coords[0][0], coords[0][1], elapsed, cumulative, 0)

    # We treat the polyline as a flat list of (start, end) segments. The
    # accumulator `seg_done_m` tracks how far through the current segment
    # we've already moved, so a leftover step from segment N can carry into
    # segment N+1 without dropping resolution.
    seg_done_m = 0.0
    seg_idx = 0
    seg_len_m = haversine_m(coords[0], coords[1])

    while seg_idx < len(coords) - 1:
        if seg_len_m <= 0:
            seg_idx += 1
            seg_done_m = 0.0
            if seg_idx < len(coords) - 1:
                seg_len_m = haversine_m(coords[seg_idx], coords[seg_idx + 1])
            continue

        remaining_in_seg = seg_len_m - seg_done_m
        if step_m <= remaining_in_seg:
            seg_done_m += step_m
            cumulative += step_m
            elapsed += tick_s
            frac = seg_done_m / seg_len_m
            lat = coords[seg_idx][0] + (coords[seg_idx + 1][0] - coords[seg_idx][0]) * frac
            lng = coords[seg_idx][1] + (coords[seg_idx + 1][1] - coords[seg_idx][1]) * frac
            yield Tick(lat, lng, elapsed, cumulative, seg_idx)
        else:
            # The full step crosses into the next segment. Consume the
            # rest of this one and absorb the leftover into the next
            # iteration's `step_m` budget.
            cumulative += remaining_in_seg
            # Time to walk that remainder, then continue counting in the
            # next segment.
            partial_time = remaining_in_seg / speed_mps
            elapsed += partial_time
            seg_idx += 1
            seg_done_m = 0.0
            if seg_idx < len(coords) - 1:
                seg_len_m = haversine_m(coords[seg_idx], coords[seg_idx + 1])
                # Continue stepping with leftover budget.
                leftover = step_m - remaining_in_seg
                while leftover > 0 and seg_idx < len(coords) - 1:
                    if seg_len_m <= 0:
                        seg_idx += 1
                        if seg_idx < len(coords) - 1:
                            seg_len_m = haversine_m(coords[seg_idx], coords[seg_idx + 1])
                        continue
                    if leftover < seg_len_m:
                        seg_done_m = leftover
                        cumulative += leftover
                        elapsed += leftover / speed_mps
                        frac = seg_done_m / seg_len_m
                        lat = coords[seg_idx][0] + (coords[seg_idx + 1][0] - coords[seg_idx][0]) * frac
                        lng = coords[seg_idx][1] + (coords[seg_idx + 1][1] - coords[seg_idx][1]) * frac
                        yield Tick(lat, lng, elapsed, cumulative, seg_idx)
                        leftover = 0
                    else:
                        cumulative += seg_len_m
                        elapsed += seg_len_m / speed_mps
                        leftover -= seg_len_m
                        seg_idx += 1
                        if seg_idx < len(coords) - 1:
                            seg_len_m = haversine_m(coords[seg_idx], coords[seg_idx + 1])
                if seg_idx >= len(coords) - 1:
                    break

    # Always end exactly at the final polyline point.
    last = coords[-1]
    final_elapsed = route_duration_s(coords, speed_mps)
    final_cumulative = route_length_m(coords)
    yield Tick(last[0], last[1], final_elapsed, final_cumulative, max(0, len(coords) - 2))
