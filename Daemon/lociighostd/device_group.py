"""Drive several iPhones from one movement run.

Everything the app can start — teleport, navigate, random walk, flower
mode — produces a stream of positions for one device. A group turns
each of those positions into one position per member, so three phones
walk the same route together instead of three separate runs drifting
apart by however long each tick took.

The default is that every member gets the *same* coordinate, which is
what "synchronised" means for the case this was asked for. A member can
carry an offset (a distance and a bearing) for the case where identical
coordinates are undesirable; 0 m is not a special case in the code, it
just lands back on the leader's position.

Pure: no device handles here, only udids and coordinates. The runtime
decides what a failure on one member means; this module decides where
each member should be.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from .flower_plan import offset_point


MAX_MEMBERS = 3
"""Three, because that is what the feature was asked for and because
every extra member adds a round trip to a tick loop that has to finish
inside one position update. Raising it is a measurement, not an edit.
"""


@dataclass(frozen=True, slots=True)
class GroupMember:
    udid: str
    offset_m: float = 0.0
    """Distance from the leader's position. 0 — the default — puts the
    member exactly on it."""

    bearing_deg: float = 0.0
    """Direction of that offset. Ignored when `offset_m` is 0."""

    def __post_init__(self) -> None:
        if not self.udid or not self.udid.strip():
            raise ValueError("a group member needs a udid")
        for name in ("offset_m", "bearing_deg"):
            if not math.isfinite(getattr(self, name)):
                raise ValueError(f"{name} must be a finite number")
        object.__setattr__(self, "udid", self.udid.strip())
        object.__setattr__(self, "offset_m", max(0.0, float(self.offset_m)))
        object.__setattr__(self, "bearing_deg", float(self.bearing_deg) % 360.0)


@dataclass(frozen=True, slots=True)
class DeviceGroup:
    """An ordered set of devices moving as one. The first member is
    the leader: the one whose position the UI draws, and the one whose
    failure stops the run."""

    members: tuple[GroupMember, ...] = field(default=())

    def __post_init__(self) -> None:
        seen: set[str] = set()
        unique: list[GroupMember] = []
        for member in self.members:
            if member.udid in seen:
                # A duplicate udid would mean two writes racing to the
                # same device every tick, which reads on the phone as
                # stuttering rather than as a mistake anyone can see.
                continue
            seen.add(member.udid)
            unique.append(member)
        object.__setattr__(self, "members", tuple(unique[:MAX_MEMBERS]))

    @property
    def udids(self) -> tuple[str, ...]:
        return tuple(m.udid for m in self.members)

    @property
    def leader(self) -> str | None:
        return self.members[0].udid if self.members else None

    @property
    def is_active(self) -> bool:
        """A group of one is just a device. Nothing needs fanning out,
        and the runtime can take its ordinary single-device path."""
        return len(self.members) > 1

    def positions(self, coord: tuple[float, float]) -> list[tuple[str, float, float]]:
        """Where each member goes for one position of the run."""
        out: list[tuple[str, float, float]] = []
        for member in self.members:
            if member.offset_m <= 0.0:
                out.append((member.udid, coord[0], coord[1]))
            else:
                lat, lng = offset_point(coord, member.offset_m, member.bearing_deg)
                out.append((member.udid, lat, lng))
        return out

    def without(self, udid: str) -> "DeviceGroup":
        """The group minus one device — what the runtime does when a
        member disconnects and the others should keep going."""
        return DeviceGroup(tuple(m for m in self.members if m.udid != udid))


def from_params(raw: dict | None) -> DeviceGroup:
    """Build a group from JSON-RPC params.

    Accepts either a plain list of udids (the common case: identical
    coordinates, no offsets) or a list of objects with offsets, so the
    app can send the simple shape without inventing empty fields.
    """
    raw = raw or {}
    entries = raw.get("members") or raw.get("udids") or ()
    members: list[GroupMember] = []
    for entry in entries:
        if isinstance(entry, str):
            if entry.strip():
                members.append(GroupMember(udid=entry))
        elif isinstance(entry, dict):
            udid = str(entry.get("udid") or "").strip()
            if not udid:
                continue
            members.append(GroupMember(
                udid=udid,
                offset_m=float(entry.get("offset_m") or 0.0),
                bearing_deg=float(entry.get("bearing_deg") or 0.0),
            ))
    return DeviceGroup(tuple(members))
