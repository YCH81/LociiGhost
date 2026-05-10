"""Wire `DeviceManager` + `LocationService` + `Navigator` into RPC handlers.

Kept deliberately thin: parse params, call the manager / navigator, return
the result. All domain validation happens in the manager / location
service / navigator; this layer just translates between RPC and Python.
"""

from __future__ import annotations

import logging
from typing import Any

from . import errors
from .device_manager import DeviceManager
from .interpolator import route_length_m
from .joystick import JoystickController
from .navigator import Navigator
from .random_walker import RandomWalker
from .routing import OsrmClient, Route, RoutingError
from .rpc import RpcServer

log = logging.getLogger(__name__)


# Speed presets in m/s. The GUI maps friendly labels to these.
SPEED_PRESETS = {
    "walking": 1.4,    # ~5 km/h
    "running": 2.8,    # ~10 km/h
    "cycling": 5.5,    # ~20 km/h
    "driving": 11.1,   # ~40 km/h
}


def register(server: RpcServer, manager: DeviceManager, osrm: OsrmClient) -> None:
    """Attach all device.* / location.* / routing.* methods to *server*."""

    # ------------------------------------------------------------------
    # device.*
    # ------------------------------------------------------------------

    @server.method("device.list")
    async def device_list() -> list[dict[str, Any]]:
        devices = await manager.list_devices()
        return [d.to_json() for d in devices]

    @server.method("device.connect")
    async def device_connect(udid: str, prefer_wifi: bool = False) -> dict[str, Any]:
        info = await manager.connect(udid, prefer_wifi=prefer_wifi)
        await server.broadcast_event("event.device_changed", {
            "udid": udid,
            "status": "connected",
            "device": info.to_json(),
        })
        return info.to_json()

    @server.method("device.reveal_developer_mode")
    async def device_reveal_developer_mode(udid: str) -> dict[str, Any]:
        return await manager.reveal_developer_mode(udid)

    @server.method("device.disconnect")
    async def device_disconnect(udid: str) -> dict[str, bool]:
        was_connected = await manager.disconnect(udid)
        if was_connected:
            await server.broadcast_event("event.device_changed", {
                "udid": udid,
                "status": "disconnected",
            })
        return {"disconnected": was_connected}

    # ------------------------------------------------------------------
    # wifi.*  (M-style direct-IP RemotePairing flow)
    # ------------------------------------------------------------------

    @server.method("wifi.repair")
    async def wifi_repair(udid: str | None = None) -> dict[str, Any]:
        """One-time pairing ritual that writes a fresh
        ~/.pymobiledevice3/remote_<UDID>.plist using a USB-attached iPhone.
        After this completes, `wifi.connect_ip` works without the cable."""
        return await manager.wifi_repair(udid=udid)

    @server.method("wifi.discover")
    async def wifi_discover(scan_subnet: bool = True) -> list[dict[str, Any]]:
        """Find iPhones reachable on the LAN: mDNS first, /24 TCP scan
        on port 49152 as fallback. Returns `[{ip, port, name, method}, ...]`."""
        return await manager.wifi_discover(scan_subnet=scan_subnet)

    @server.method("wifi.connect_ip")
    async def wifi_connect_ip(
        ip: str, port: int = 49152, udid: str | None = None
    ) -> dict[str, Any]:
        """Connect to an iPhone at the given IP via direct RemotePairing
        (no Bonjour browse needed). Returns the resolved DeviceInfo."""
        info = await manager.connect_wifi_ip(ip=ip, port=port, udid=udid)
        await server.broadcast_event("event.device_changed", {
            "udid": info.udid,
            "status": "connected",
            "device": info.to_json(),
        })
        return info.to_json()

    # ------------------------------------------------------------------
    # routing.*
    # ------------------------------------------------------------------

    @server.method("routing.route")
    async def routing_route(
        profile: str = "driving",
        # Same dual shape as location.navigate: either a stops list of
        # length >= 2, or the legacy 2-point from_/to_ pair.
        stops: list[dict[str, float]] | None = None,
        from_lat: float | None = None,
        from_lng: float | None = None,
        to_lat: float | None = None,
        to_lng: float | None = None,
    ) -> dict[str, Any]:
        waypoints: list[tuple[float, float]]
        if stops is not None:
            if len(stops) < 2:
                raise errors.RpcError(
                    code=errors.PYMD3_ERROR,
                    message="stops must have at least 2 waypoints",
                )
            waypoints = []
            for s in stops:
                lat = float(s["lat"])
                lng = float(s["lng"])
                _validate_coord(lat, lng)
                waypoints.append((lat, lng))
        else:
            if None in (from_lat, from_lng, to_lat, to_lng):
                raise errors.RpcError(
                    code=errors.PYMD3_ERROR,
                    message="missing waypoints (provide either stops or from_/to_)",
                )
            _validate_coord(from_lat, from_lng)            # type: ignore[arg-type]
            _validate_coord(to_lat, to_lng)                # type: ignore[arg-type]
            waypoints = [(from_lat, from_lng), (to_lat, to_lng)]   # type: ignore[list-item]
        try:
            route = await osrm.route_through(waypoints, profile)
        except RoutingError as exc:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message=str(exc),
            ) from exc
        return route.to_json()

    # ------------------------------------------------------------------
    # location.*
    # ------------------------------------------------------------------

    @server.method("location.teleport")
    async def location_teleport(udid: str, lat: float, lng: float) -> dict[str, Any]:
        _validate_coord(lat, lng)
        # Stop any active mover so it doesn't fight the teleport.
        await _stop_all_movement(manager, udid, server)

        loc = await manager.location_for(udid)
        await loc.set(float(lat), float(lng))
        await server.broadcast_event("event.position_update", {
            "udid": udid,
            "lat": lat,
            "lng": lng,
            "source": "teleport",
        })
        return {"ok": True, "lat": lat, "lng": lng}

    @server.method("location.restore")
    async def location_restore(udid: str) -> dict[str, bool]:
        await _stop_all_movement(manager, udid, server)
        loc = await manager.location_for(udid)
        await loc.clear()
        await server.broadcast_event("event.position_update", {
            "udid": udid,
            "source": "restored",
        })
        return {"ok": True}

    @server.method("location.navigate")
    async def location_navigate(
        udid: str,
        profile: str = "driving",
        speed_mps: float | None = None,
        # Either:
        #   stops=[{lat,lng}, ...]  with len >= 2 (origin + 1+ destinations)
        # or the legacy from_lat/from_lng/to_lat/to_lng pair (kept for
        # backward compatibility with older clients).
        stops: list[dict[str, float]] | None = None,
        from_lat: float | None = None,
        from_lng: float | None = None,
        to_lat: float | None = None,
        to_lng: float | None = None,
        # When true, skip OSRM and treat each consecutive pair of
        # waypoints as a straight-line segment ("as the crow flies").
        # Useful for places OSRM has no road graph for (open water,
        # off-road, indoor floor plans), and for scripted demos where
        # following actual streets is overkill.
        straight_line: bool = False,
        # Number of times to walk the route. 1 = single trip (default).
        # 2+ = loop, automatically closing the route by routing from the
        # last waypoint back to the first and concatenating that closed
        # loop `laps` times. Useful for "drive this circuit five times".
        laps: int = 1,
    ) -> dict[str, Any]:
        if speed_mps is None:
            speed_mps = SPEED_PRESETS.get(profile, SPEED_PRESETS["driving"])
        if speed_mps <= 0:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message=f"Invalid speed: {speed_mps}",
            )

        waypoints: list[tuple[float, float]]
        if stops is not None:
            if len(stops) < 2:
                raise errors.RpcError(
                    code=errors.PYMD3_ERROR,
                    message="stops must have at least origin + 1 destination",
                )
            waypoints = []
            for s in stops:
                lat = float(s["lat"])
                lng = float(s["lng"])
                _validate_coord(lat, lng)
                waypoints.append((lat, lng))
        else:
            if None in (from_lat, from_lng, to_lat, to_lng):
                raise errors.RpcError(
                    code=errors.PYMD3_ERROR,
                    message="missing waypoints (provide either stops or from_/to_)",
                )
            _validate_coord(from_lat, from_lng)            # type: ignore[arg-type]
            _validate_coord(to_lat, to_lng)                # type: ignore[arg-type]
            waypoints = [(from_lat, from_lng), (to_lat, to_lng)]   # type: ignore[list-item]

        # For loop trips, force the waypoint chain to close on itself
        # before routing, so the OSRM/straight-line geometry already
        # contains the path back to the start. Repeating that closed
        # geometry N times is just one polyline concat — the navigator
        # doesn't need any awareness of laps.
        laps = max(1, int(laps))
        if laps > 1 and waypoints[0] != waypoints[-1]:
            waypoints = waypoints + [waypoints[0]]

        if straight_line:
            base_route = _straight_line_route(waypoints, speed_mps, profile)
        else:
            try:
                base_route = await osrm.route_through(waypoints, profile)
            except RoutingError as exc:
                raise errors.RpcError(code=errors.PYMD3_ERROR, message=str(exc)) from exc

        if laps > 1:
            one_lap = list(base_route.coordinates)
            full = list(one_lap)
            for _ in range(laps - 1):
                # Drop the duplicate first point that would otherwise
                # cause the polyline to "stutter" at the seam.
                full.extend(one_lap[1:])
            route = Route(
                coordinates=full,
                distance_m=base_route.distance_m * laps,
                duration_s=base_route.duration_s * laps,
                profile=profile,
            )
        else:
            route = base_route

        await _stop_all_movement(manager, udid, server)
        loc = await manager.location_for(udid)

        async def emit(method: str, status) -> None:
            await server.broadcast_event(method, {"udid": udid, **status.to_json()})

        nav = Navigator(
            location=loc,
            coords=route.coordinates,
            speed_mps=speed_mps,
            profile=profile,
            on_event=emit,
        )
        await manager.set_navigator(udid, nav)
        nav.start()
        await server.broadcast_event("event.state_changed", {
            "udid": udid,
            **nav.status().to_json(),
        })

        return {
            "ok": True,
            "route": route.to_json(),
            "speed_mps": speed_mps,
        }

    @server.method("location.pause")
    async def location_pause(udid: str) -> dict[str, str]:
        nav = await _navigator_for(manager, udid)
        await nav.pause()
        return {"state": nav.state}

    @server.method("location.resume")
    async def location_resume(udid: str) -> dict[str, str]:
        nav = await _navigator_for(manager, udid)
        await nav.resume()
        return {"state": nav.state}

    @server.method("location.stop")
    async def location_stop(udid: str) -> dict[str, bool]:
        await _stop_all_movement(manager, udid, server)
        return {"ok": True}

    @server.method("location.apply_speed")
    async def location_apply_speed(udid: str, speed_mps: float) -> dict[str, float]:
        nav = await _navigator_for(manager, udid)
        await nav.apply_speed(speed_mps)
        return {"speed_mps": speed_mps}

    @server.method("location.status")
    async def location_status(udid: str) -> dict[str, Any]:
        sess = await manager.session_for(udid)
        if sess.navigator is None:
            return {"state": "idle"}
        return sess.navigator.status().to_json()

    # ------------------------------------------------------------------
    # location.random_walk — drift inside a circle
    # ------------------------------------------------------------------

    @server.method("location.random_walk")
    async def location_random_walk(
        udid: str,
        center_lat: float,
        center_lng: float,
        radius_m: float,
        min_speed_mps: float = 0.8,
        max_speed_mps: float = 1.6,
    ) -> dict[str, Any]:
        _validate_coord(center_lat, center_lng)
        if radius_m <= 0 or radius_m > 50_000:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message=f"radius_m must be between 0 and 50000 (got {radius_m})",
            )
        if min_speed_mps <= 0 or max_speed_mps <= 0 or min_speed_mps > max_speed_mps:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message="invalid speed band",
            )

        await _stop_all_movement(manager, udid, server)
        loc = await manager.location_for(udid)

        async def emit(method: str, status) -> None:
            await server.broadcast_event(method, {"udid": udid, **status.to_json()})

        walker = RandomWalker(
            location=loc,
            center=(center_lat, center_lng),
            radius_m=radius_m,
            min_speed_mps=min_speed_mps,
            max_speed_mps=max_speed_mps,
            on_event=emit,
        )
        await manager.set_walker(udid, walker)
        walker.start()
        await server.broadcast_event("event.state_changed", {
            "udid": udid,
            "mode": "random_walk",
            **walker.status().to_json(),
        })
        return {"ok": True, **walker.status().to_json()}

    # ------------------------------------------------------------------
    # location.joystick — real-time WASD-style control
    # ------------------------------------------------------------------

    @server.method("location.joystick.start")
    async def location_joystick_start(
        udid: str,
        lat: float,
        lng: float,
    ) -> dict[str, Any]:
        _validate_coord(lat, lng)
        await _stop_all_movement(manager, udid, server)
        loc = await manager.location_for(udid)

        async def emit(method: str, status) -> None:
            await server.broadcast_event(method, {"udid": udid, **status.to_json()})

        ctrl = JoystickController(
            location=loc,
            origin=(lat, lng),
            on_event=emit,
        )
        await manager.set_joystick(udid, ctrl)
        ctrl.start()
        await server.broadcast_event("event.state_changed", {
            "udid": udid,
            "mode": "joystick",
            **ctrl.status().to_json(),
        })
        return {"ok": True, **ctrl.status().to_json()}

    @server.method("location.joystick.update")
    async def location_joystick_update(
        udid: str,
        heading_deg: float,
        speed_mps: float,
    ) -> dict[str, Any]:
        sess = await manager.session_for(udid)
        if sess.joystick is None:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message="No active joystick session — call location.joystick.start first.",
            )
        await sess.joystick.update(heading_deg, speed_mps)
        return sess.joystick.status().to_json()


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

def _validate_coord(lat: float, lng: float) -> None:
    if not (-90.0 <= lat <= 90.0):
        raise errors.RpcError(
            code=errors.PYMD3_ERROR,
            message=f"Invalid latitude: {lat} (must be -90..90)",
        )
    if not (-180.0 <= lng <= 180.0):
        raise errors.RpcError(
            code=errors.PYMD3_ERROR,
            message=f"Invalid longitude: {lng} (must be -180..180)",
        )


async def _navigator_for(manager: DeviceManager, udid: str) -> Navigator:
    sess = await manager.session_for(udid)
    if sess.navigator is None:
        raise errors.RpcError(
            code=errors.PYMD3_ERROR,
            message=f"No active navigation for {udid}",
        )
    return sess.navigator


def _straight_line_route(
    waypoints: list[tuple[float, float]],
    speed_mps: float,
    profile: str,
) -> Route:
    """Build a Route that visits each waypoint along the great-circle line
    between consecutive points -- no OSRM call, no road awareness.

    The Navigator's interpolator already linearly steps between adjacent
    polyline points, so handing it the raw waypoints is enough; we don't
    need to densify the line.
    """
    distance = route_length_m(waypoints)
    duration = distance / speed_mps if speed_mps > 0 else 0.0
    return Route(
        coordinates=list(waypoints),
        distance_m=distance,
        duration_s=duration,
        profile=profile,
    )


async def _stop_navigation_if_any(
    manager: DeviceManager, udid: str, server: RpcServer
) -> None:
    """Stop the navigator on `udid` if one is running. Best-effort: a missing
    session or a navigator that already finished is fine."""
    try:
        sess = await manager.session_for(udid)
    except errors.RpcError:
        return
    if sess.navigator is None:
        return
    try:
        await sess.navigator.stop()
    finally:
        sess.navigator = None
        await server.broadcast_event("event.state_changed", {
            "udid": udid,
            "state": "idle",
        })


async def _stop_all_movement(
    manager: DeviceManager, udid: str, server: RpcServer
) -> None:
    """Tear down every active mover on the session — navigator, random
    walker, joystick. Used by every `location.*` entry point that wants
    to be the *only* mover for a device."""
    try:
        sess = await manager.session_for(udid)
    except errors.RpcError:
        return
    for attr in ("navigator", "walker", "joystick"):
        runner = getattr(sess, attr, None)
        if runner is None:
            continue
        try:
            await runner.stop()
        except Exception:
            pass
        setattr(sess, attr, None)
    await server.broadcast_event("event.state_changed", {
        "udid": udid,
        "state": "idle",
    })
