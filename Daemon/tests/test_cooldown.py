"""The cooldown gate: distance in, minimum wait out."""

from __future__ import annotations

import pytest

from lociighostd.cooldown import (
    CooldownPolicy,
    CooldownStep,
    check,
    from_params,
)


TAIPEI = (25.0339, 121.5645)
TAICHUNG = (24.1477, 120.6736)          # ~133 km from Taipei


def test_disabled_is_the_default_and_gates_nothing():
    policy = CooldownPolicy()
    assert policy.enabled is False
    assert policy.required_wait_s(1_000_000) == 0.0
    assert check(policy, TAIPEI, 0.0, TAICHUNG, 1.0).allowed


def test_the_speed_rule_is_distance_over_speed():
    policy = CooldownPolicy(enabled=True, max_speed_kmh=60.0)
    # 60 km/h is a kilometre a minute.
    assert policy.required_wait_s(1_000) == pytest.approx(60.0, abs=0.01)
    assert policy.required_wait_s(30_000) == pytest.approx(1_800.0, abs=0.5)


def test_a_zero_speed_disables_only_the_speed_rule():
    policy = CooldownPolicy(enabled=True, max_speed_kmh=0.0, minimum_gap_s=5.0)
    assert policy.required_wait_s(1_000_000) == 5.0


def test_the_floor_covers_what_the_speed_rule_cannot():
    """Two positions a metre apart pass any speed rule, a hundred times
    a second. The floor is the only thing that catches that."""
    policy = CooldownPolicy(enabled=True, max_speed_kmh=200.0, minimum_gap_s=3.0)
    assert policy.required_wait_s(1.0) == 3.0


def test_user_rows_are_a_minimum_never_a_discount():
    """A row saying "100 km needs 30 minutes" must not let a jump
    through faster than the speed rule would have."""
    policy = CooldownPolicy(
        enabled=True,
        max_speed_kmh=60.0,                       # 100 km -> 100 minutes
        steps=(CooldownStep(distance_km=100, wait_minutes=30),),
    )
    assert policy.required_wait_s(100_000) == pytest.approx(6_000.0, abs=1)


def test_the_longest_matching_row_wins():
    policy = CooldownPolicy(
        enabled=True,
        steps=(CooldownStep(distance_km=100, wait_minutes=30),
               CooldownStep(distance_km=10, wait_minutes=5)),
    )
    assert policy.required_wait_s(5_000) == 0.0        # under every row
    assert policy.required_wait_s(50_000) == 300.0     # the 10 km row
    assert policy.required_wait_s(500_000) == 1_800.0  # the 100 km row


def test_rows_are_sorted_however_they_arrive():
    policy = CooldownPolicy(
        enabled=True,
        steps=(CooldownStep(distance_km=100, wait_minutes=30),
               CooldownStep(distance_km=1, wait_minutes=1)),
    )
    assert [s.distance_km for s in policy.steps] == [1.0, 100.0]


# ── check() ─────────────────────────────────────────────────────────


def test_the_first_position_of_a_session_always_passes():
    """There is nothing for it to be implausible relative to, and a
    blocked first teleport looks exactly like a broken app."""
    policy = CooldownPolicy(enabled=True, max_speed_kmh=1.0)
    verdict = check(policy, None, None, TAICHUNG, now=0.0)
    assert verdict.allowed and verdict.remaining_s == 0.0


def test_remaining_counts_down_with_elapsed_time():
    policy = CooldownPolicy(enabled=True, minimum_gap_s=10.0)
    early = check(policy, TAIPEI, 100.0, TAIPEI, now=104.0)
    assert not early.allowed
    assert early.remaining_s == pytest.approx(6.0)
    later = check(policy, TAIPEI, 100.0, TAIPEI, now=111.0)
    assert later.allowed and later.remaining_s == 0.0


def test_the_verdict_reports_the_distance_it_measured():
    policy = CooldownPolicy(enabled=True, max_speed_kmh=60.0)
    verdict = check(policy, TAIPEI, 0.0, TAICHUNG, now=1.0)
    assert verdict.distance_m == pytest.approx(133_500, rel=0.02)
    assert not verdict.allowed


def test_a_backwards_clock_does_not_hand_out_free_jumps():
    """Sleep and NTP corrections both move the clock backwards. Treating
    that as negative elapsed time would make `required - elapsed`
    *larger*; treating it as a free pass would be worse still. Neither:
    no time has passed."""
    policy = CooldownPolicy(enabled=True, minimum_gap_s=10.0)
    verdict = check(policy, TAIPEI, 500.0, TAIPEI, now=100.0)
    assert not verdict.allowed
    assert verdict.remaining_s == pytest.approx(10.0)


def test_non_finite_distance_raises():
    policy = CooldownPolicy(enabled=True)
    with pytest.raises(ValueError):
        policy.required_wait_s(float("nan"))
    with pytest.raises(ValueError):
        policy.required_wait_s(-5.0)


def test_non_finite_settings_raise():
    with pytest.raises(ValueError):
        CooldownPolicy(max_speed_kmh=float("inf"))
    with pytest.raises(ValueError):
        CooldownStep(distance_km=float("nan"), wait_minutes=1)


# ── Params ──────────────────────────────────────────────────────────


def test_params_round_trip_including_rows():
    policy = from_params({
        "enabled": True,
        "max_speed_kmh": 90,
        "minimum_gap_s": 4,
        "steps": [{"distance_km": 20, "wait_minutes": 7}],
        "unknown_key_from_v1_18": 1,
    })
    assert policy.enabled and policy.max_speed_kmh == 90
    assert policy.minimum_gap_s == 4
    assert policy.steps == (CooldownStep(20.0, 7.0),)


def test_no_params_is_the_disabled_default():
    assert from_params(None) == CooldownPolicy()
    assert from_params({}) == CooldownPolicy()
