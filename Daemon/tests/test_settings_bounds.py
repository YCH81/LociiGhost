"""The app's flower bounds and the daemon's have to be the same numbers.

Both sides hold them: the daemon clamps authoritatively, and the app
needs the ranges to build steppers that only offer values the daemon
will accept. Two copies of a limit drift silently — a stepper offering
200 segments that quietly become 20 looks like the app ignoring the
user. So this reads the Swift source and compares.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from lociighostd import flower_plan


SWIFT = (Path(__file__).resolve().parents[2]
         / "App" / "Sources" / "LociiGhostCore" / "FlowerConfig.swift")


@pytest.fixture(scope="module")
def swift_source() -> str:
    if not SWIFT.exists():
        pytest.skip(f"{SWIFT} not present (daemon checked out on its own?)")
    return SWIFT.read_text(encoding="utf-8")


def _closed_range(source: str, name: str) -> tuple[float, float]:
    match = re.search(
        rf"static let {name}\s*=\s*([0-9_.]+)\s*\.\.\.\s*([0-9_.]+)", source)
    assert match, f"no {name} in {SWIFT.name}"
    return float(match.group(1).replace("_", "")), float(match.group(2).replace("_", ""))


def test_segment_bounds_match(swift_source):
    assert _closed_range(swift_source, "segmentRange") == (
        flower_plan.MIN_SEGMENTS, flower_plan.MAX_SEGMENTS)


def test_lap_bounds_match(swift_source):
    assert _closed_range(swift_source, "lapRange") == (
        flower_plan.MIN_LAPS, flower_plan.MAX_LAPS)


def test_round_bounds_match(swift_source):
    assert _closed_range(swift_source, "roundRange") == (1, flower_plan.MAX_ROUNDS)


def test_radius_bounds_match(swift_source):
    assert _closed_range(swift_source, "radiusRange") == (
        flower_plan.MIN_RADIUS_M, flower_plan.MAX_RADIUS_M)


def test_the_half_lap_step_matches(swift_source):
    match = re.search(r"static let lapStep\s*=\s*([0-9.]+)", swift_source)
    assert match and float(match.group(1)) == 0.5


def test_the_app_sends_the_field_names_the_daemon_reads(swift_source):
    """`with_defaults` ignores keys it doesn't know, so a typo on the
    app side is a setting that silently does nothing."""
    sent = set(re.findall(r'"([a-z_]+)":\s*(?:radiusM|Double|laps|speedMps|'
                          r'waitBeforeSeconds|waitAfterSeconds|dwellSeconds)',
                          swift_source))
    assert sent, "could not find the rpcParameters dictionary"
    known = {
        "radius_m", "segments", "laps", "rounds", "wait_before_s",
        "wait_after_s", "dwell_s", "speed_mps", "teleport_between",
    }
    assert sent <= known, f"the app sends keys the daemon ignores: {sent - known}"
