"""Wire `DeviceManager` + `LocationService` + `Navigator` into RPC handlers.

Kept deliberately thin: parse params, call the manager / navigator, return
the result. All domain validation happens in the manager / location
service / navigator; this layer just translates between RPC and Python.
"""

from __future__ import annotations

import logging
from typing import Any

from . import cooldown as cooldown_mod
from . import errors
from .device_group import DeviceGroup, GroupMember
from .device_group import from_params as group_from_params
from .device_manager import DeviceManager
from .flower_plan import FlowerSettings, summarise, with_defaults
from .flower_runner import FlowerRunner
from .group_location import GroupLocation
from .interpolator import route_length_m
from .joystick import JoystickController
from .navigator import Navigator
from .random_walker import RandomWalker
from .routing import GoogleDirectionsClient, NoRouteError, OsrmClient, Route, RoutingError
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
        After this completes, `wifi.connect_ip` works without the cable.

        Broadcasts `event.wifi_pair_progress` at each stage so the GUI
        can render a 2-step Trust-prompt progress bar without polling.
        Stages emitted: usbmux_query → usb_pairing → tunnel_setup →
        remote_pairing → done.
        """
        async def _on_progress(stage: str, message: str) -> None:
            await server.broadcast_event("event.wifi_pair_progress", {
                "stage": stage,
                "message": message,
                "udid": udid,
            })
        try:
            result = await manager.wifi_repair(udid=udid, progress=_on_progress)
        except Exception:
            # Surface a final "failed" event so the GUI can clear its
            # "step 1/2" progress text instead of leaving it stuck.
            await server.broadcast_event("event.wifi_pair_progress", {
                "stage": "failed",
                "message": "Pairing failed; see error message.",
                "udid": udid,
            })
            raise
        return result

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
            for i, s in enumerate(stops):
                # v1.15.2 audit (X17): a missing or non-numeric key
                # used to raise KeyError/TypeError, which rpc.py's
                # catch-all turned into "Internal error: 'lat'" —
                # technically safe, completely unactionable.
                try:
                    lat = float(s["lat"])
                    lng = float(s["lng"])
                except (KeyError, TypeError, ValueError) as exc:
                    raise errors.RpcError(
                        code=errors.PYMD3_ERROR,
                        message=f"stop #{i} needs numeric lat and lng",
                    ) from exc
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

    # ------------------------------------------------------------------
    # Groups — one run, several phones (v1.17)
    # ------------------------------------------------------------------

    async def _location_for_run(udid: str, group_params: Any) -> Any:
        """The location service a mover should write to.

        For a lone device that is the device's own service, unchanged.
        For a group it is a `GroupLocation`, which is the only place
        that knows about groups at all — movers just call `set`, so a
        mover written next year is group-capable by having been
        written.
        """
        group = group_from_params(group_params)
        if not group.is_active:
            return await manager.location_for(udid)

        # The device the call names leads, wherever it appears in the
        # list: the run's status, its events and its stop all belong to
        # that session.
        members = [m for m in group.members if m.udid == udid]
        members += [m for m in group.members if m.udid != udid]
        if not members or members[0].udid != udid:
            members = [GroupMember(udid)] + members

        leader_service = await manager.location_for(udid)
        services: dict[str, Any] = {udid: leader_service}
        usable = [members[0]]
        skipped: list[str] = []
        for member in members[1:]:
            try:
                services[member.udid] = await manager.location_for(member.udid)
            except errors.RpcError:
                # One phone being unplugged shouldn't refuse the run for
                # the other two — but it must not pass silently either.
                skipped.append(member.udid)
                continue
            usable.append(member)

        if skipped:
            await server.broadcast_event("event.group_changed", {
                "udid": udid,
                "skipped": skipped,
                "reason": "not_connected",
            })

        resolved = DeviceGroup(tuple(usable))
        if not resolved.is_active:
            return leader_service

        async def dropped(member_udid: str, error: BaseException) -> None:
            await server.broadcast_event("event.group_changed", {
                "udid": udid,
                "dropped": [member_udid],
                "reason": "push_failed",
                "detail": str(error),
            })

        async def positions(moved: list[tuple[str, float, float]]) -> None:
            await server.broadcast_event("event.group_positions", {
                "udid": udid,
                "members": [
                    {"udid": member, "lat": lat, "lng": lng}
                    for member, lat, lng in moved
                ],
            })

        return GroupLocation(resolved, services,
                             on_member_dropped=dropped,
                             on_positions=positions)

    # ------------------------------------------------------------------
    # Cooldown — the user's own plausibility gate (v1.17)
    # ------------------------------------------------------------------
    #
    # The policy lives on the DeviceManager, not in this closure: the
    # phone remote starts the same jumps through the HTTP server, and a
    # gate only this path consulted would be one the user could walk
    # around from their phone without knowing it. One policy for the
    # whole daemon, too — a phone that gated differently from the one
    # beside it would be indistinguishable from a bug.

    @server.method("settings.cooldown")
    async def settings_cooldown(policy: dict[str, Any] | None = None) -> dict[str, Any]:
        """Set the gate, or read it back when called with nothing.

        Held in memory only. The Mac owns the user's settings and
        re-sends this on connect; a second copy in the daemon is a
        second thing to keep in step, and the two disagreeing is worse
        than re-sending three numbers.
        """
        if policy is not None:
            manager.cooldown_policy = cooldown_mod.from_params(policy)
        current = manager.cooldown_policy
        return {
            "enabled": current.enabled,
            "max_speed_kmh": current.max_speed_kmh,
            "minimum_gap_s": current.minimum_gap_s,
            "steps": [
                {"distance_km": step.distance_km, "wait_minutes": step.wait_minutes}
                for step in current.steps
            ],
        }

    async def _gate_jump(udid: str, lat: float, lng: float) -> None:
        """Refuse a jump the user's own settings call implausible.

        Applies to explicit teleports and to the hop that *starts* a
        movement mode — the jumps. It deliberately does not interrupt a
        run already in progress: continuous movement is speed-limited
        by construction, and a gate that stalled a route halfway would
        look like the app hanging.
        """
        verdict = await manager.cooldown_verdict(udid, (float(lat), float(lng)))
        if not verdict.allowed:
            raise errors.cooldown_active(
                verdict.remaining_s, verdict.required_s, verdict.distance_m)

    @server.method("location.teleport")
    async def location_teleport(
        udid: str,
        lat: float,
        lng: float,
        group: Any = None,
    ) -> dict[str, Any]:
        _validate_coord(lat, lng)
        await _gate_jump(udid, lat, lng)
        # Stop any active mover so it doesn't fight the teleport.
        await _stop_all_movement(manager, udid, server)

        loc = await _location_for_run(udid, group)
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

    @server.method("location.gold_ditto")
    async def location_gold_ditto(udid: str, lat: float, lng: float) -> dict[str, Any]:
        """Pikmin Bloom 拉金盆 exploit cycle (ported from LocWarp 0.2.143).

        Two-step burst inside the game's flower-bud animation window:

          1. push the iPhone's GPS to A (the user's real location,
             passed in from the Mac)
          2. immediately clear the simulation so the iPhone reverts
             to real GPS

        The user is expected to have manually opened the in-game
        flower bud BEFORE invoking this RPC. The bud's animation
        freezes the game's location verification just long enough
        for the GPS round-trip to look atomic from the game's
        perspective — when the animation ends, the game sees the
        player at A (their real spot) and credits the gold-pot
        reward there. The gold-pot location itself stays untouched
        so the same pot can be milked repeatedly.

        Differs from `teleport` + `restore` in that we deliberately
        skip the `_stop_all_movement` call and the
        `event.position_update` broadcast: the desktop map's camera
        should stay parked on the gold pot, not jump to A.
        """
        _validate_coord(lat, lng)
        loc = await manager.location_for(udid)
        await loc.set(float(lat), float(lng))
        await server.broadcast_event("event.gold_ditto", {
            "udid": udid,
            "phase": "teleported",
            "lat": lat,
            "lng": lng,
        })
        await loc.clear()
        await server.broadcast_event("event.gold_ditto", {
            "udid": udid,
            "phase": "restored",
        })
        return {"ok": True, "lat": lat, "lng": lng}

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
        # v1.9.1: which routing backend to use. Defaults to the OSRM
        # demo for backward compatibility with clients that don't pass
        # this field at all. "google" routes through Google Directions
        # using `engine_api_key`; "straight_line" forces straight_line
        # mode regardless of the explicit straight_line flag above.
        engine: str = "osrm_demo",
        engine_api_key: str | None = None,
        # v1.10: Mac-side MapKit pre-resolves the route and ships the
        # whole polyline. When present, we skip our own engine dispatch
        # entirely and treat these coords as the authoritative route —
        # MKDirections lives on the Apple SDK side and the Python daemon
        # can't call it, so the Mac has to do that work and hand us the
        # result. Each entry is {"lat": float, "lng": float}.
        polyline: list[dict[str, float]] | None = None,
        # v1.17: when present, every position of this run goes to each
        # member as well. `_location_for_run` is where that happens;
        # the navigator never learns about it.
        group: Any = None,
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
            for i, s in enumerate(stops):
                # v1.15.2 audit (X17): a missing or non-numeric key
                # used to raise KeyError/TypeError, which rpc.py's
                # catch-all turned into "Internal error: 'lat'" —
                # technically safe, completely unactionable.
                try:
                    lat = float(s["lat"])
                    lng = float(s["lng"])
                except (KeyError, TypeError, ValueError) as exc:
                    raise errors.RpcError(
                        code=errors.PYMD3_ERROR,
                        message=f"stop #{i} needs numeric lat and lng",
                    ) from exc
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

        # v1.10 Mac-resolved polyline: when the Mac has already done
        # the routing (MapKit path), it sends us the final polyline
        # directly. Skip every engine here — the supplied coords are
        # the route. Distance is recomputed from geometry; duration
        # gets re-derived from speed_mps further down so the UI ETA
        # tracks the SpeedPicker exactly the same way it does for
        # daemon-resolved routes.
        if polyline is not None:
            mac_coords: list[tuple[float, float]] = []
            for i, p in enumerate(polyline):
                try:
                    lat = float(p["lat"])
                    lng = float(p["lng"])
                except (KeyError, TypeError, ValueError) as exc:
                    raise errors.RpcError(
                        code=errors.PYMD3_ERROR,
                        message=f"polyline point #{i} needs numeric "
                                f"lat and lng",
                    ) from exc
                _validate_coord(lat, lng)
                mac_coords.append((lat, lng))
            if len(mac_coords) < 2:
                raise errors.RpcError(
                    code=errors.PYMD3_ERROR,
                    message="polyline must have at least 2 points",
                )
            base_route = Route(
                coordinates=mac_coords,
                distance_m=route_length_m(mac_coords),
                duration_s=0.0,                # recomputed below from speed_mps
                profile=profile,
            )
            laps = max(1, int(laps))
            # v1.15.2 audit (L13): the loop-closing step above operates
            # on `waypoints`, which this branch skips entirely, so a
            # multi-lap Mac-resolved route was concatenated open-ended:
            # every seam became a straight line from the last point
            # back to the first, WALKED at the configured speed rather
            # than jumped. The App currently forces laps=1 on this
            # path so it isn't reachable today — which is exactly why
            # it needs closing now rather than after the next
            # refactor re-enables it.
            if laps > 1 and mac_coords[0] != mac_coords[-1]:
                mac_coords = mac_coords + [mac_coords[0]]
                base_route = Route(
                    coordinates=mac_coords,
                    distance_m=route_length_m(mac_coords),
                    duration_s=0.0,
                    profile=profile,
                )
            # Skip the engine dispatch fork below.
            goto_after_routing = True
        else:
            goto_after_routing = False

        # v1.9.1 engine dispatch. `straight_line=True` always wins
        # over engine — if either the explicit flag or
        # engine=="straight_line" is set, we skip network routing.
        # For engine=="google" we use GoogleDirectionsClient with
        # the user-supplied API key. Everything else falls back to
        # the daemon's shared OsrmClient.
        effective_straight = straight_line or engine == "straight_line"
        if goto_after_routing:
            pass    # base_route already built from Mac-supplied polyline
        elif effective_straight:
            base_route = _straight_line_route(waypoints, speed_mps, profile)
        elif engine == "google":
            if not engine_api_key:
                raise errors.RpcError(
                    code=errors.PYMD3_ERROR,
                    message="Google Directions engine requires an API key. "
                            "Paste one in Settings → Geocoding, or switch "
                            "the routing engine back to OSRM Public Demo.",
                )
            try:
                base_route = await GoogleDirectionsClient(engine_api_key).route_through(
                    waypoints, profile,
                )
            except RoutingError as exc:
                raise errors.RpcError(code=errors.PYMD3_ERROR, message=str(exc)) from exc
        else:
            try:
                base_route = await osrm.route_through(waypoints, profile)
            except NoRouteError:
                # bike/foot can't bridge every waypoint pair (highway-only
                # crossings, restricted tunnels, etc.). Fall back to car
                # — graph is denser so it almost always finds a path, and
                # actual playback speed comes from speed_mps anyway, so
                # the user-perceived mode still matches what they picked.
                log.info(
                    "OSRM NoRoute for profile=%s — retrying as car",
                    profile,
                )
                try:
                    base_route = await osrm.route_through(waypoints, "driving")
                except RoutingError as exc2:
                    raise errors.RpcError(
                        code=errors.PYMD3_ERROR, message=str(exc2),
                    ) from exc2
            except RoutingError as exc:
                raise errors.RpcError(code=errors.PYMD3_ERROR, message=str(exc)) from exc

        if laps > 1:
            one_lap = list(base_route.coordinates)
            full = list(one_lap)
            for _ in range(laps - 1):
                # Drop the duplicate first point that would otherwise
                # cause the polyline to "stutter" at the seam.
                full.extend(one_lap[1:])
            coords = full
            total_distance = base_route.distance_m * laps
        else:
            coords = list(base_route.coordinates)
            total_distance = base_route.distance_m

        # Recompute ETA from the SpeedPicker setting so the time the
        # UI shows matches what playback will actually take. The
        # engine's own duration is unreliable here: OSRM/Google return
        # durations at their own assumed profile speed, while the
        # SpeedPicker is free-form (and also wins for cases where we
        # fell back to "driving" geometry after NoRoute on bike/foot
        # — see the except NoRouteError branch above).
        total_duration = total_distance / speed_mps if speed_mps > 0 else 0.0
        route = Route(
            coordinates=coords,
            distance_m=total_distance,
            duration_s=total_duration,
            profile=profile,
        )

        loc = await _location_for_run(udid, group)

        async def emit(method: str, status) -> None:
            await server.broadcast_event(method, {"udid": udid, **status.to_json()})

        nav = Navigator(
            location=loc,
            coords=route.coordinates,
            speed_mps=speed_mps,
            profile=profile,
            on_event=emit,
        )
        # Stop-and-attach is one critical section now; see
        # DeviceManager.attach_runner (v1.15.2 audit L4). We don't
        # broadcast the stop -- the state_changed for the new run
        # follows immediately and a "stopped" in between made the
        # Mac's ETA panel flicker.
        await manager.attach_runner(udid, "navigator", nav)
        await server.broadcast_event("event.state_changed", {
            "udid": udid,
            **nav.status().to_json(),
        })

        return {
            "ok": True,
            "route": route.to_json(),
            "speed_mps": speed_mps,
        }

    @server.method("location.group_detach")
    async def location_group_detach(udid: str) -> dict[str, Any]:
        """Drop every follower from the run that is already moving.

        The leader keeps going — that is the whole point of turning
        sync off rather than pressing Stop.
        """
        sess = await manager.session_for(udid)
        dropped: list[str] = []
        for attr in manager.MOVER_ATTRS:
            runner = getattr(sess, attr, None)
            loc = getattr(runner, "_location", None) if runner is not None else None
            if isinstance(loc, GroupLocation):
                dropped.extend(loc.detach_followers())
        if dropped:
            await server.broadcast_event("event.group_changed", {
                "udid": udid,
                "dropped": dropped,
                "reason": "sync_disabled",
            })
        return {"dropped": dropped}

    @server.method("location.pause")
    async def location_pause(udid: str) -> dict[str, Any]:
        nav = await _pausable_for(manager, udid)
        applied = await nav.pause()
        # `applied` lets the Mac tell "paused" from "there was nothing
        # left to pause" instead of optimistically rendering the former
        # (v1.15.2 audit L8).
        return {"state": nav.state, "applied": applied}

    @server.method("location.resume")
    async def location_resume(udid: str) -> dict[str, Any]:
        nav = await _pausable_for(manager, udid)
        applied = await nav.resume()
        return {"state": nav.state, "applied": applied}

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
        routing_engine: str = "straight",
        profile: str = "walking",
        dwell_seconds: float | None = None,
        dwell_seconds_min: float | None = None,
        dwell_seconds_max: float | None = None,
        group: Any = None,
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
        if routing_engine not in ("straight", "map"):
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message=f"routing_engine must be 'straight' or 'map' (got {routing_engine!r})",
            )
        # v1.17 sends a range; older Mac builds send the single
        # `dwell_seconds`. Fold both into one pair so the walker only
        # ever sees min/max.
        lo = dwell_seconds_min if dwell_seconds_min is not None else dwell_seconds
        hi = dwell_seconds_max if dwell_seconds_max is not None else lo
        if lo is not None and lo <= 0:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message=f"dwell seconds must be > 0 when set (got {lo})",
            )
        if lo is not None and hi is not None and hi < lo:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message=f"dwell_seconds_max ({hi}) must be >= dwell_seconds_min ({lo})",
            )

        await _gate_jump(udid, center_lat, center_lng)
        loc = await _location_for_run(udid, group)

        async def emit(method: str, status) -> None:
            await server.broadcast_event(method, {"udid": udid, **status.to_json()})

        walker = RandomWalker(
            location=loc,
            center=(center_lat, center_lng),
            radius_m=radius_m,
            min_speed_mps=min_speed_mps,
            max_speed_mps=max_speed_mps,
            on_event=emit,
            osrm=osrm,
            routing_engine=routing_engine,
            profile=profile,
            dwell_seconds_override=lo,
            dwell_seconds_max=hi,
        )
        await manager.attach_runner(udid, "walker", walker)
        await server.broadcast_event("event.state_changed", {
            "udid": udid,
            "mode": "random_walk",
            **walker.status().to_json(),
        })
        return {"ok": True, **walker.status().to_json()}

    # ------------------------------------------------------------------
    # location.flower — orbit each waypoint, lap after lap
    # ------------------------------------------------------------------

    def _flower_centers(points: list[Any]) -> list[tuple[float, float]]:
        centers: list[tuple[float, float]] = []
        for point in points or []:
            if isinstance(point, dict):
                lat, lng = point.get("lat"), point.get("lng")
            elif isinstance(point, (list, tuple)) and len(point) >= 2:
                lat, lng = point[0], point[1]
            else:
                raise errors.RpcError(
                    code=errors.PYMD3_ERROR,
                    message=f"unreadable waypoint {point!r}",
                )
            _validate_coord(float(lat), float(lng))
            centers.append((float(lat), float(lng)))
        if not centers:
            raise errors.RpcError(
                code=errors.PYMD3_ERROR,
                message="flower mode needs at least one waypoint",
            )
        return centers

    @server.method("location.flower_estimate")
    async def location_flower_estimate(
        points: list[Any],
        settings: dict[str, Any] | None = None,
        origin_lat: float | None = None,
        origin_lng: float | None = None,
    ) -> dict[str, Any]:
        """What the settings panel shows while the user is still
        choosing. Touches no device on purpose — the panel is open
        before anything is connected, and an estimate that needs a
        phone would be an estimate nobody sees."""
        centers = _flower_centers(points)
        origin = None
        if origin_lat is not None and origin_lng is not None:
            _validate_coord(origin_lat, origin_lng)
            origin = (origin_lat, origin_lng)
        return summarise(centers, with_defaults(settings), origin)

    @server.method("location.flower")
    async def location_flower(
        udid: str,
        points: list[Any],
        settings: dict[str, Any] | None = None,
        resume_from_step: int = 0,
        group: Any = None,
    ) -> dict[str, Any]:
        centers = _flower_centers(points)
        config: FlowerSettings = with_defaults(settings)

        await _gate_jump(udid, centers[0][0], centers[0][1])
        loc = await _location_for_run(udid, group)

        async def emit(method: str, status) -> None:
            await server.broadcast_event(method, {"udid": udid, **status.to_json()})

        # Resume starts from where the phone is, not from the first
        # waypoint: a run that dropped on the far side of the city
        # would otherwise walk back across it before carrying on.
        start = getattr(loc, "last_lat_lng", None) or centers[0]

        runner = FlowerRunner(
            location=loc,
            centers=centers,
            settings=config,
            on_event=emit,
            start_position=start,
            completed_steps=max(0, int(resume_from_step)),
        )
        await manager.attach_runner(udid, "flower", runner)
        await server.broadcast_event("event.state_changed", {
            "udid": udid,
            "mode": "flower",
            **runner.status().to_json(),
        })
        return {"ok": True, **runner.status().to_json()}

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
        loc = await manager.location_for(udid)

        async def emit(method: str, status) -> None:
            await server.broadcast_event(method, {"udid": udid, **status.to_json()})

        ctrl = JoystickController(
            location=loc,
            origin=(lat, lng),
            on_event=emit,
        )
        await manager.attach_runner(udid, "joystick", ctrl)
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

    # ------------------------------------------------------------------
    # phone.* — query / force-end the mobile-web phone-control session
    # ------------------------------------------------------------------

    @server.method("phone.session")
    async def phone_session() -> dict[str, Any]:
        """Returns whether ANY phone tab is currently logged in,
        plus the de-duped set of iPhone UDIDs being driven across
        all sessions. Mac UI uses `udids` to decide per-device
        lockout — switching to a non-targeted iPhone or the Map
        keeps the Mac usable.

        Lazy sweeps stale sessions inline so a long-idle Mac that
        just reconnected doesn't see ghost active sessions.
        """
        auth = getattr(server, "phone_auth", None)
        if auth is None:
            return {"active": False, "udids": []}
        # Inline sweep so the answer is always fresh.
        removed = auth.sweep_stale()
        if removed > 0:
            await server.broadcast_event("event.phone_session", {
                "active": auth.is_any_active(),
                "udids": auth.controlling_udids(),
            })
        return {
            "active": auth.is_any_active(),
            "udids": auth.controlling_udids(),
        }

    @server.method("phone.sync_mode")
    async def phone_sync_mode_get() -> dict[str, Any]:
        auth = getattr(server, "phone_auth", None)
        return {"sync": bool(auth and getattr(auth, "sync_mode", False))}

    @server.method("phone.set_sync_mode")
    async def phone_sync_mode_set(sync: bool) -> dict[str, Any]:
        auth = getattr(server, "phone_auth", None)
        if auth is None:
            return {"ok": False, "reason": "no_http_server"}
        was = getattr(auth, "sync_mode", False)
        auth.sync_mode = bool(sync)
        if was != auth.sync_mode:
            await server.broadcast_event("event.sync_mode", {"sync": auth.sync_mode})
        return {"ok": True, "sync": auth.sync_mode}

    @server.method("phone.force_logout")
    async def phone_force_logout() -> dict[str, Any]:
        """Mac-initiated revoke. Rotates the PIN + token so the
        currently-paired phone tab gets booted, then broadcasts
        the session-ended event."""
        auth = getattr(server, "phone_auth", None)
        if auth is None:
            return {"ok": False, "reason": "no_http_server"}
        was_any = bool(auth and auth.is_any_active())
        try:
            # Kick EVERY active session (multi-session model)
            # and rotate the PIN so the kicked phones can't
            # reconnect with the old credentials. The Mac
            # "stop phone control" button is the hard reset.
            auth.clear_all()
            auth.rotate_pin()
        except Exception:
            return {"ok": False}
        if was_any:
            await server.broadcast_event("event.phone_session", {
                "active": False, "udids": [],
            })
        return {"ok": True}


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


async def _pausable_for(manager: DeviceManager, udid: str) -> Any:
    """Whatever is moving `udid` and knows how to hold position.

    Pause used to reach only `sess.navigator`, so pressing it during a
    flower run raised "No active navigation" — the button looked broken
    rather than unimplemented. Any mover that grows a `pause`/`resume`
    pair is picked up here without another edit.
    """
    sess = await manager.session_for(udid)
    for attr in manager.MOVER_ATTRS:
        runner = getattr(sess, attr, None)
        if runner is not None and hasattr(runner, "pause"):
            return runner
    raise errors.RpcError(
        code=errors.PYMD3_ERROR,
        message=f"Nothing is moving {udid} that can be paused",
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


async def _stop_all_movement(
    manager: DeviceManager, udid: str, server: RpcServer
) -> None:
    """Tear down every active mover on the session — navigator, random
    walker, joystick. Used by every `location.*` entry point that wants
    to be the *only* mover for a device.

    v1.10.8 fix: only emit `state="idle"` when we actually stopped
    something. Earlier behaviour was to emit the idle event
    unconditionally at the end, which races against the very next
    handler call (`location.navigate` calls `_stop_all_movement` first
    thing, then immediately starts a fresh navigator and emits
    `state="moving"`). If the spurious `state="idle"` reached the Mac
    after the new `navigate` RPC reply had already set up
    `AppState.navigation`, it would clear `navigation` back to nil and
    the BottomBar's ETA panel would silently disappear for the rest of
    the route — even though the daemon kept playing. Now the idle
    event only fires when there really was a runner to stop.
    """
    stopped_any = await manager.stop_all_movement(udid)
    if stopped_any:
        # v1.15.2 audit (L5): "stopped", not "idle". The Mac treats
        # "idle" as natural route completion and uses it to drive lap
        # continuation, so a stop issued as part of the next lap's own
        # teleport looked like a second completion and decremented the
        # lap counter twice -- three laps ran as two. A stop we
        # initiated is by definition user-driven; natural completion is
        # emitted by the Navigator's own loop.
        await server.broadcast_event("event.state_changed", {
            "udid": udid,
            "state": "stopped",
        })
