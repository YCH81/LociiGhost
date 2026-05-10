"""Plain dataclass models that serialise to / from RPC JSON cleanly."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Optional


@dataclass(frozen=True, slots=True)
class DeviceInfo:
    """A discoverable iOS device. Frozen so it can be safely passed around."""

    udid: str
    name: str
    ios_version: str
    transport: str                          # "usb" | "network" — the active/preferred one
    connected: bool = False
    developer_mode: Optional[bool] = None   # None = unknown/not queryable
    # Every transport usbmuxd reports for this UDID. Useful for the GUI
    # to render "USB + WiFi" badges and offer a "Connect via WiFi"
    # action even when the device is currently plugged in via USB.
    transports: tuple[str, ...] = ()
    # True if `~/.pymobiledevice3/remote_<UDID>.plist` exists, i.e. the
    # M-style WiFi pairing ritual has already run for this UDID and the
    # GUI can hide / disable its "Pair for WiFi" button. None means we
    # haven't checked yet (kept distinct from False so the GUI can stay
    # quiet during the initial paint instead of flashing "needs pairing").
    wifi_paired: Optional[bool] = None
    # When the session was opened via direct-IP RemotePairing
    # (`connect_wifi_ip`), these record the peer the tunnel is going
    # to. The GUI uses them to highlight the matching row in the WiFi
    # Devices list (so only the actually-connected candidate flips to
    # "Disconnect", instead of every row claiming the connection).
    peer_ip: Optional[str] = None
    peer_port: Optional[int] = None

    def to_json(self) -> dict[str, Any]:
        d = asdict(self)
        # Serialise the tuple as a JSON array for the Swift client.
        d["transports"] = list(self.transports)
        return d


@dataclass(frozen=True, slots=True)
class Coordinate:
    lat: float
    lng: float

    def to_json(self) -> dict[str, float]:
        return {"lat": self.lat, "lng": self.lng}


def parse_ios_version(s: str) -> tuple[int, ...]:
    """`'17.4.1'` -> `(17, 4, 1)`. Returns `(0, 0)` if unparseable."""
    try:
        return tuple(int(p) for p in s.split("."))
    except (ValueError, AttributeError):
        return (0, 0)
