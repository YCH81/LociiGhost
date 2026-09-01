"""Group sync at the point where it belongs: the location service."""

from __future__ import annotations

import asyncio

import pytest

from lociighostd.device_group import DeviceGroup, GroupMember
from lociighostd.group_location import GroupLocation
from lociighostd.interpolator import haversine_m

from ._fakes import FakeLocation


TAIPEI = (25.0339, 121.5645)


def _group(*members: GroupMember) -> DeviceGroup:
    return DeviceGroup(members)


@pytest.mark.asyncio
async def test_every_member_gets_the_same_coordinate():
    a, b, c = FakeLocation(), FakeLocation(), FakeLocation()
    loc = GroupLocation(_group(GroupMember("a"), GroupMember("b"), GroupMember("c")),
                        {"a": a, "b": b, "c": c})
    await loc.set(*TAIPEI)
    assert a.calls == b.calls == c.calls == [TAIPEI]
    assert loc.last_lat_lng == TAIPEI


@pytest.mark.asyncio
async def test_an_offset_member_is_pushed_its_own_coordinate():
    a, b = FakeLocation(), FakeLocation()
    loc = GroupLocation(
        _group(GroupMember("a"), GroupMember("b", offset_m=30.0, bearing_deg=0.0)),
        {"a": a, "b": b})
    await loc.set(*TAIPEI)
    assert a.calls == [TAIPEI]
    assert haversine_m(TAIPEI, b.calls[0]) == pytest.approx(30.0, abs=0.01)


@pytest.mark.asyncio
async def test_a_leader_failure_propagates():
    """A run whose main phone has lost its channel has stopped meaning
    anything; the mover should see the error and stop."""
    lead = FakeLocation(fail_after=0)
    follower = FakeLocation()
    loc = GroupLocation(_group(GroupMember("lead"), GroupMember("follow")),
                        {"lead": lead, "follow": follower})
    with pytest.raises(RuntimeError):
        await loc.set(*TAIPEI)
    # …and the followers were not moved somewhere the leader never went.
    assert follower.calls == []


@pytest.mark.asyncio
async def test_a_follower_failure_drops_that_member_and_the_run_continues():
    lead, good, bad = FakeLocation(), FakeLocation(), FakeLocation(fail_after=0)
    dropped: list[str] = []

    async def on_dropped(udid, error):
        dropped.append(udid)

    loc = GroupLocation(
        _group(GroupMember("lead"), GroupMember("good"), GroupMember("bad")),
        {"lead": lead, "good": good, "bad": bad},
        on_member_dropped=on_dropped)

    await loc.set(*TAIPEI)
    assert dropped == ["bad"]
    assert loc.group.udids == ("lead", "good")

    # The next push doesn't even try the dropped member.
    await loc.set(25.04, 121.57)
    assert len(lead.calls) == 2
    assert len(good.calls) == 2
    assert len(bad.calls) == 0


@pytest.mark.asyncio
async def test_a_handler_that_throws_does_not_take_the_run_with_it():
    async def broken(udid, error):
        raise RuntimeError("handler exploded")

    lead, bad = FakeLocation(), FakeLocation(fail_after=0)
    loc = GroupLocation(_group(GroupMember("lead"), GroupMember("bad")),
                        {"lead": lead, "bad": bad}, on_member_dropped=broken)
    await loc.set(*TAIPEI)
    assert loc.group.udids == ("lead",)


@pytest.mark.asyncio
async def test_restore_clears_every_member_even_if_one_fails():
    """One failure must not leave the others spoofed — that is the
    state a user can't get out of without finding this app again."""
    a, b, c = FakeLocation(), FakeLocation(fail_after=0), FakeLocation()
    # `clear` on the failing fake still counts; make it raise instead.
    async def boom():
        raise RuntimeError("channel down")
    b.clear = boom

    loc = GroupLocation(_group(GroupMember("a"), GroupMember("b"), GroupMember("c")),
                        {"a": a, "b": b, "c": c})
    await loc.set(*TAIPEI)
    await loc.clear()
    assert a.cleared == 1
    assert c.cleared == 1
    assert loc.last_lat_lng is None


@pytest.mark.asyncio
async def test_the_group_service_is_not_a_stand_in_for_a_device_service():
    """Movers only ever call set and clear. Everything else on a
    LocationService belongs to one device — the health loop reads
    liveness from the session's own service, and a forwarding shim
    here would make this object look like the leader's while being a
    different thing."""
    lead, follow = FakeLocation(), FakeLocation()
    lead.consecutive_keepalive_failures = 7
    loc = GroupLocation(_group(GroupMember("lead"), GroupMember("follow")),
                        {"lead": lead, "follow": follow})
    assert loc.consecutive_keepalive_failures == 0
    assert loc.leader_service is lead


def test_a_member_without_a_service_is_a_programming_error():
    with pytest.raises(ValueError):
        GroupLocation(_group(GroupMember("a"), GroupMember("ghost")),
                      {"a": FakeLocation()})


def test_an_empty_group_is_rejected():
    with pytest.raises(ValueError):
        GroupLocation(DeviceGroup(()), {})
