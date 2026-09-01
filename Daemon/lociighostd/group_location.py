"""Push one run's positions to several phones.

A mover — navigator, walker, flower runner — knows how to move *a*
device: it computes a position and calls `location.set`. Group sync
therefore doesn't belong in the movers at all. It belongs in the thing
they call: a LocationService that happens to write to three phones
instead of one.

That is the whole design. Nothing above this file learns about groups,
so a mover written next year is group-capable by having been written at
all, and there is no per-mover fan-out to keep in step.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Awaitable, Callable, Optional

from .device_group import DeviceGroup
from .location_service import LocationService

log = logging.getLogger(__name__)


MemberFailureHandler = Callable[[str, BaseException], Awaitable[None]]


class GroupLocation(LocationService):
    """A LocationService that writes to every member of a group.

    The leader is authoritative: its failures propagate, because a run
    whose main phone has lost its channel is a run that has stopped
    meaning anything. A follower's failure drops that follower from the
    group and the run continues — the alternative is three phones
    stopping because one of them was unplugged.
    """

    def __init__(
        self,
        group: DeviceGroup,
        services: dict[str, LocationService],
        on_member_dropped: Optional[MemberFailureHandler] = None,
    ) -> None:
        missing = [udid for udid in group.udids if udid not in services]
        if missing:
            raise ValueError(f"no location service for group members: {missing}")
        if not group.members:
            raise ValueError("a group needs at least one member")

        self._group = group
        self._services = dict(services)
        self._on_member_dropped = on_member_dropped
        self.last_lat_lng: Optional[tuple[float, float]] = None
        self._call_lock = asyncio.Lock()

    @property
    def group(self) -> DeviceGroup:
        """The group as it stands now — members that failed are gone."""
        return self._group

    @property
    def leader_service(self) -> LocationService:
        leader = self._group.leader
        assert leader is not None                  # guarded in __init__
        return self._services[leader]

    async def set(self, lat: float, lng: float, *,
                  retries: Optional[int] = None) -> None:
        positions = self._group.positions((lat, lng))
        if not positions:
            return

        leader_udid, leader_lat, leader_lng = positions[0]
        # Leader first and awaited alone: if the run can't continue, it
        # should fail before the followers have been moved somewhere
        # the leader never went.
        await self._services[leader_udid].set(leader_lat, leader_lng, retries=retries)
        self.last_lat_lng = (lat, lng)

        followers = positions[1:]
        if not followers:
            return

        results = await asyncio.gather(
            *(self._services[udid].set(flat, flng, retries=retries)
              for udid, flat, flng in followers),
            return_exceptions=True,
        )
        for (udid, _, _), result in zip(followers, results):
            if isinstance(result, BaseException):
                await self._drop(udid, result)

    async def clear(self) -> None:
        """Restore every member. One failure must not leave the others
        spoofed — that is the state a user cannot get out of without
        finding this app again."""
        results = await asyncio.gather(
            *(self._services[udid].clear() for udid in self._group.udids),
            return_exceptions=True,
        )
        self.last_lat_lng = None
        for udid, result in zip(self._group.udids, results):
            if isinstance(result, BaseException):
                log.warning("group: could not restore %s: %r", udid, result)

    async def _drop(self, udid: str, error: BaseException) -> None:
        log.warning("group: dropping %s after a failed push: %r", udid, error)
        self._group = self._group.without(udid)
        if self._on_member_dropped is not None:
            try:
                await self._on_member_dropped(udid, error)
            except Exception:                              # noqa: BLE001
                log.exception("group: member-dropped handler failed")

    # No attribute forwarding to the leader on purpose.
    #
    # Movers only ever call `set` and `clear` — that is the whole
    # surface they use. Everything else on a LocationService (keepalive
    # counters, liveness fields, the DVT session) belongs to one
    # device, and each session keeps its own real service for exactly
    # that: the health loop reads liveness from there, not from here. A
    # forwarding shim would have made this object *look* like the
    # leader's service while being a different thing, which is how a
    # keepalive ends up firing for a group that no longer has that
    # member.
