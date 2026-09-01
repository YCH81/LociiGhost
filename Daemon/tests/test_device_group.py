"""Group sync: one run, several phones."""

from __future__ import annotations

import pytest

from lociighostd.device_group import (
    MAX_MEMBERS,
    DeviceGroup,
    GroupMember,
    from_params,
)
from lociighostd.interpolator import haversine_m


TAIPEI = (25.0339, 121.5645)


def test_the_default_puts_every_member_on_the_same_coordinate():
    """This is the whole point of the feature as asked for: three
    phones at one coordinate, not three phones near one coordinate."""
    group = DeviceGroup((GroupMember("a"), GroupMember("b"), GroupMember("c")))
    positions = group.positions(TAIPEI)
    assert [p[0] for p in positions] == ["a", "b", "c"]
    for _, lat, lng in positions:
        assert (lat, lng) == TAIPEI


def test_an_offset_member_lands_that_far_away_on_that_bearing():
    group = DeviceGroup((
        GroupMember("lead"),
        GroupMember("wing", offset_m=25.0, bearing_deg=90.0),
    ))
    lead, wing = group.positions(TAIPEI)
    assert (lead[1], lead[2]) == TAIPEI
    assert haversine_m(TAIPEI, (wing[1], wing[2])) == pytest.approx(25.0, abs=0.01)
    assert wing[2] > TAIPEI[1]                     # east


def test_a_zero_offset_is_not_a_special_case_it_is_just_the_leader():
    group = DeviceGroup((GroupMember("x", offset_m=0.0, bearing_deg=137.0),))
    _, lat, lng = group.positions(TAIPEI)[0]
    assert (lat, lng) == TAIPEI


def test_duplicate_udids_are_dropped():
    """Two entries for one phone would race two writes to it every
    tick, which shows up as stutter rather than as an error."""
    group = DeviceGroup((GroupMember("a"), GroupMember("a", offset_m=10)))
    assert group.udids == ("a",)


def test_the_group_is_capped():
    group = DeviceGroup(tuple(GroupMember(f"d{i}") for i in range(10)))
    assert len(group.members) == MAX_MEMBERS


def test_a_group_of_one_is_not_active():
    """One device needs no fan-out, and the runtime should take its
    ordinary single-device path."""
    assert not DeviceGroup((GroupMember("solo"),)).is_active
    assert not DeviceGroup(()).is_active
    assert DeviceGroup((GroupMember("a"), GroupMember("b"))).is_active


def test_the_first_member_leads():
    group = DeviceGroup((GroupMember("first"), GroupMember("second")))
    assert group.leader == "first"
    assert DeviceGroup(()).leader is None


def test_dropping_a_member_keeps_the_rest_and_their_order():
    group = DeviceGroup((GroupMember("a"), GroupMember("b"), GroupMember("c")))
    assert group.without("b").udids == ("a", "c")
    assert group.without("nobody").udids == ("a", "b", "c")


def test_a_member_needs_a_udid():
    with pytest.raises(ValueError):
        GroupMember("   ")


def test_non_finite_offsets_raise():
    with pytest.raises(ValueError):
        GroupMember("a", offset_m=float("nan"))
    with pytest.raises(ValueError):
        GroupMember("a", bearing_deg=float("inf"))


def test_bearings_wrap_and_negative_offsets_clamp():
    member = GroupMember("a", offset_m=-5.0, bearing_deg=450.0)
    assert member.offset_m == 0.0
    assert member.bearing_deg == 90.0


# ── Params ──────────────────────────────────────────────────────────


def test_a_plain_list_of_udids_is_the_simple_shape():
    group = from_params({"udids": ["a", "b", "c"]})
    assert group.udids == ("a", "b", "c")
    assert all(m.offset_m == 0.0 for m in group.members)


def test_objects_carry_offsets():
    group = from_params({"members": [
        {"udid": "a"},
        {"udid": "b", "offset_m": 12, "bearing_deg": 180},
    ]})
    assert group.members[1].offset_m == 12.0
    assert group.members[1].bearing_deg == 180.0


def test_blank_and_malformed_entries_are_skipped():
    group = from_params({"members": ["", {"udid": ""}, {"nope": 1}, "real"]})
    assert group.udids == ("real",)


def test_no_params_is_an_empty_group():
    assert from_params(None).members == ()
    assert from_params({}).members == ()
