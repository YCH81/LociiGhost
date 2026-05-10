"""Mobile phone control HTTP server.

Lets a phone on the same WiFi reach a small mobile UI hosted by
LociiGhost and operate the connected iPhone (teleport, navigate,
stop, restore). Mirrors M v0.2.143's `/phone` flow, ported into
our asyncio + DeviceManager world.

  Auth model
  ──────────
  * Backend generates a 32-hex `token` and a 6-digit `pin` at startup
    and on every `/api/phone/rotate` call.
  * Phone opens `http://<lan-ip>:<port>/phone`, types the PIN, and
    the page POSTs the PIN to `/api/phone/auth` to receive the token.
    The token lives in `localStorage` for subsequent reloads.
  * Every action endpoint requires the token via either:
        - `X-LociiGhost-Token` header
        - `?t=<token>` query param
  * `/api/phone/info` and `/api/phone/rotate` are localhost-only so
    the desktop GUI can fetch URL / PIN without exposing them to LAN.

The server lives in the same asyncio loop as the JSON-RPC server,
spawned as a sibling task at daemon startup. All actions go through
the SAME `DeviceManager` instance the RPC server uses, so phone
operations and desktop operations stay consistent (e.g., a phone
teleport while a desktop navigation is running cleanly cancels nav
and switches the iPhone to the typed lat/lng).
"""

from __future__ import annotations

import asyncio
import logging
import secrets
import socket
import time
from pathlib import Path
from typing import Any, Optional

import httpx
import uvicorn
from fastapi import (
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Query,
    Request,
)
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    JSONResponse,
    RedirectResponse,
)
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import errors
from .device_manager import DeviceManager
from .routing import OsrmClient, RoutingError

log = logging.getLogger("lociighostd.http")

# Port preference list. We try each in order and use the first one
# we can actually bind. 8779 (not 8777) is the FIRST candidate so
# we don't fight M LocWarp's backend if the user happens to have it
# installed and running — that's the original /Applications/LocWarp
# Electron app, which permanently owns 8777 while it's open. The
# remaining ports are arbitrary fallbacks for unusual collisions.
DEFAULT_HTTP_PORT = 8779
PORT_CANDIDATES = [8779, 8780, 8781, 8788, 8789, 8800]


# ── Auth state ────────────────────────────────────────────────────


class _PhoneAuth:
    """In-memory rotating PIN + token. Loses state on daemon restart,
    which is the desired behaviour — the user is forced to re-pair
    their phone after a host reboot, which keeps stale phone tabs
    from sneaking back in after a long-running desktop session."""

    def __init__(self) -> None:
        self.token: str = secrets.token_hex(16)            # 32 hex chars
        self.pin: str = f"{secrets.randbelow(1_000_000):06d}"
        self.created_at: float = time.monotonic()

    def rotate(self) -> None:
        self.token = secrets.token_hex(16)
        self.pin = f"{secrets.randbelow(1_000_000):06d}"
        self.created_at = time.monotonic()

    def check_token(self, supplied: Optional[str]) -> bool:
        if not supplied:
            return False
        # `secrets.compare_digest` is constant-time vs the obvious `==`
        # so a network attacker can't time-side-channel the token.
        return secrets.compare_digest(supplied, self.token)


# ── Helpers ───────────────────────────────────────────────────────


def _is_localhost(request: Request) -> bool:
    """True iff the HTTP request reached us over loopback. Used to
    gate `/api/phone/info` and `/api/phone/rotate` so the URL and
    fresh-PIN endpoints are NEVER exposed to the LAN — only the
    desktop GUI (running on this same Mac) can fetch them."""
    host = (request.client.host if request.client else "") or ""
    return host in ("127.0.0.1", "::1", "localhost")


def _get_lan_ip() -> Optional[str]:
    """Return the Mac's primary LAN IPv4. Used to display
    "http://<ip>:8777/phone" to the user. Same UDP-connect trick as
    the WiFi-discover module — no packet is actually sent."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


# ── Request / response models ─────────────────────────────────────


class AuthRequest(BaseModel):
    pin: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")


class TeleportRequest(BaseModel):
    lat: float
    lng: float
    udid: Optional[str] = None


class NavigateRequest(BaseModel):
    lat: float
    lng: float
    profile: str = "driving"
    speed: Optional[float] = None
    udid: Optional[str] = None


class UdidOnlyRequest(BaseModel):
    udid: Optional[str] = None


class JoystickStartRequest(BaseModel):
    lat: float
    lng: float
    udid: Optional[str] = None


class JoystickUpdateRequest(BaseModel):
    heading_deg: float
    speed_mps: float
    udid: Optional[str] = None


class RandomWalkRequest(BaseModel):
    center_lat: float
    center_lng: float
    radius_m: float
    min_speed_mps: float = 0.8
    max_speed_mps: float = 1.6
    udid: Optional[str] = None


# ── App factory ───────────────────────────────────────────────────


def create_http_app(
    manager: DeviceManager,
    osrm: OsrmClient,
    *,
    bound_port: int,
    rpc_server: Optional[Any] = None,
) -> FastAPI:
    auth = _PhoneAuth()
    static_dir = Path(__file__).parent / "static"
    app = FastAPI(title="LociiGhost Phone Control")

    # Token dependency — returns the token if valid, raises 401.
    async def require_token(
        request: Request,
        x_lociighost_token: Optional[str] = Header(default=None),
        t: Optional[str] = Query(default=None),
    ) -> str:
        supplied = x_lociighost_token or t
        if not auth.check_token(supplied):
            raise HTTPException(status_code=401, detail="invalid_token")
        return supplied  # type: ignore[return-value]

    # ---- Auth / pairing ----

    @app.post("/api/phone/auth")
    async def phone_auth(req: AuthRequest) -> dict[str, Any]:
        # Constant-time compare so a network attacker can't time-side-
        # channel the PIN either.
        if not secrets.compare_digest(req.pin, auth.pin):
            raise HTTPException(status_code=403, detail="bad_pin")
        return {"token": auth.token}

    @app.get("/api/phone/info")
    async def phone_info(request: Request) -> dict[str, Any]:
        if not _is_localhost(request):
            raise HTTPException(status_code=404)
        ip = _get_lan_ip() or "127.0.0.1"
        return {
            "url": f"http://{ip}:{bound_port}/phone",
            "pin": auth.pin,
            "lan_ip": ip,
            "port": bound_port,
        }

    @app.post("/api/phone/rotate")
    async def phone_rotate(request: Request) -> dict[str, Any]:
        if not _is_localhost(request):
            raise HTTPException(status_code=404)
        auth.rotate()
        return {"ok": True, "pin": auth.pin}

    # ---- State (read) ----

    @app.get("/api/phone/state")
    async def phone_state(_token: str = Depends(require_token)) -> dict[str, Any]:
        devices = await manager.list_devices()
        out = []
        for d in devices:
            entry = d.to_json()
            sess = manager._sessions.get(d.udid)        # noqa: SLF001
            if sess is None:
                out.append(entry)
                continue

            # Live iPhone position (last successful set call) so phone
            # can render a blue dot on the map.
            if sess.location is not None:
                pos = getattr(sess.location, "last_lat_lng", None)
                if pos is not None:
                    entry["current_lat"] = pos[0]
                    entry["current_lng"] = pos[1]

            # Active navigation route — phone uses this to draw the
            # planned-route polyline and to enable follow-the-dot
            # auto-pan while the iPhone moves along it.
            nav = sess.navigator
            if nav is not None:
                coords = getattr(nav, "_coords", None)
                if coords:
                    entry["route_coords"] = [[c[0], c[1]] for c in coords]
                    entry["mode"] = "navigate"

            # Active random-walk circle — phone draws it as a
            # translucent disc so the user sees the wander bounds the
            # whole time, not only while the start-overlay was open.
            walker = sess.walker
            if walker is not None:
                center = getattr(walker, "_center", None)
                radius = getattr(walker, "_radius_m", None)
                if center is not None and radius is not None:
                    entry["walk_center_lat"] = center[0]
                    entry["walk_center_lng"] = center[1]
                    entry["walk_radius_m"]   = radius
                    entry["mode"] = "random_walk"

            # Active joystick — just a flag; the map dot is enough.
            if sess.joystick is not None:
                entry["mode"] = "joystick"

            out.append(entry)
        return {"devices": out}

    # ---- Actions (mutate) ----

    def _resolve_udid(supplied: Optional[str]) -> str:
        """Pick which device an action targets. Caller-supplied UDID
        wins; otherwise the first connected device. Raises 400 if
        nothing's connected so the phone doesn't silently fail."""
        if supplied:
            return supplied
        for udid, sess in manager._sessions.items():  # noqa: SLF001
            if sess.transport in ("usb", "network"):
                return udid
        raise HTTPException(status_code=400, detail="no_device_connected")

    async def _emit(event_method: str, params: dict[str, Any]) -> None:
        """Forward a state change to RPC clients (the desktop GUI)
        so a phone-triggered action shows up live in the desktop
        window. No-op when the daemon is running standalone (no
        RPC server attached)."""
        if rpc_server is None:
            return
        try:
            await rpc_server.broadcast_event(event_method, params)
        except Exception:
            log.debug("broadcast_event failed", exc_info=True)

    @app.post("/api/phone/teleport")
    async def phone_teleport(
        req: TeleportRequest, _token: str = Depends(require_token)
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid)
        loc = await manager.location_for(udid)
        # Cancel any in-flight navigator before teleport — same
        # semantics as the desktop right-click "Teleport" path.
        sess = await manager.session_for(udid)
        for runner_attr in ("navigator", "walker", "joystick"):
            runner = getattr(sess, runner_attr, None)
            if runner is not None:
                try:
                    await runner.stop()
                except Exception:
                    pass
                setattr(sess, runner_attr, None)
                # Tell the desktop the previous mode is over so it
                # clears its NavigationVM / RandomWalkVM / JoystickVM.
                await _emit("event.state_changed", {
                    "udid": udid, "mode": "idle",
                })
        await loc.set(req.lat, req.lng)
        # Broadcast position so the desktop's `simulatedLocation`
        # tracks the phone's pin instead of staying at wherever the
        # desktop last set it.
        await _emit("event.position_update", {
            "udid": udid, "lat": req.lat, "lng": req.lng,
        })
        return {"ok": True, "udid": udid, "lat": req.lat, "lng": req.lng}

    @app.post("/api/phone/restore")
    async def phone_restore(
        req: UdidOnlyRequest, _token: str = Depends(require_token)
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid)
        loc = await manager.location_for(udid)
        await loc.clear()
        await _emit("event.state_changed", {
            "udid": udid, "mode": "restored",
        })
        return {"ok": True, "udid": udid}

    @app.post("/api/phone/stop")
    async def phone_stop(
        req: UdidOnlyRequest, _token: str = Depends(require_token)
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid)
        sess = await manager.session_for(udid)
        for runner_attr in ("navigator", "walker", "joystick"):
            runner = getattr(sess, runner_attr, None)
            if runner is not None:
                try:
                    await runner.stop()
                except Exception:
                    pass
                setattr(sess, runner_attr, None)
        await _emit("event.state_changed", {
            "udid": udid, "mode": "idle",
        })
        return {"ok": True, "udid": udid}

    @app.post("/api/phone/navigate")
    async def phone_navigate(
        req: NavigateRequest, _token: str = Depends(require_token)
    ) -> dict[str, Any]:
        # Phone-side navigate uses the same OSRM round-trip the
        # desktop does, then a one-shot Navigator. The phone doesn't
        # currently support multi-stop / loop / random-walk; teleport
        # and one-leg navigate cover the day-to-day "I'm not at the
        # Mac" use case and the rest can stay desktop-only for now.
        from .navigator import Navigator      # local import — heavy modules
        from .interpolator import route_length_m

        udid = _resolve_udid(req.udid)
        sess = await manager.session_for(udid)
        loc = await manager.location_for(udid)

        # Cancel existing nav.
        if sess.navigator is not None:
            try:
                await sess.navigator.stop()
            except Exception:
                pass
            sess.navigator = None

        # Origin: the last position we successfully pushed to this
        # iPhone, tracked by `LocationService.last_lat_lng`. Phone
        # doesn't carry its own map state so the daemon must remember.
        origin = getattr(loc, "last_lat_lng", None)
        if origin is None:
            # Phone hit Navigate without ever having teleported first.
            # We can't route from "nowhere" — the iPhone's real GPS
            # isn't readable through DVT either. Tell the user to
            # teleport once before navigating. Falling through with
            # `(req.lat, req.lng)` would build a zero-length route
            # and OSRM would 400, which the phone surfaces as a
            # generic "request_failed" toast — way less helpful than
            # this explicit hint.
            raise HTTPException(
                status_code=400,
                detail=(
                    "no_origin: tap the map and Teleport once first, "
                    "so the iPhone has a starting position to route from."
                ),
            )

        try:
            route = await osrm.route(
                origin[0], origin[1], req.lat, req.lng, profile=req.profile
            )
        except RoutingError as exc:
            raise HTTPException(status_code=502, detail=f"routing_failed: {exc}")

        # Pick speed: caller-provided > profile default.
        speed_mps = req.speed
        if speed_mps is None:
            speed_mps = {
                "walking": 1.4,
                "cycling": 5.5,
                "driving": 11.1,
            }.get(req.profile, 11.1)

        # Forward Navigator state changes via the same RPC event
        # channel the desktop GUI subscribes to. Without this the
        # desktop window doesn't show the live progress bar / ETA
        # for a phone-started navigation.
        async def _nav_emit(method: str, status) -> None:
            payload = status.to_json() if hasattr(status, "to_json") else dict(status)
            payload["udid"] = udid
            await _emit(method, payload)

        nav = Navigator(
            location=loc,
            coords=route.coordinates,
            speed_mps=speed_mps,
            profile=req.profile,
            on_event=_nav_emit,
        )
        await manager.set_navigator(udid, nav)
        nav.start()                # NOT async — fires a background task
        await _emit("event.state_changed", {
            "udid": udid, "mode": "navigate",
            **nav.status().to_json(),
        })

        return {
            "ok": True,
            "udid": udid,
            "distance_m": route_length_m(route.coordinates),
            "speed_mps": speed_mps,
        }

    @app.post("/api/phone/joystick/start")
    async def phone_joystick_start(
        req: JoystickStartRequest, _token: str = Depends(require_token)
    ) -> dict[str, Any]:
        """Start a joystick session at the given lat/lng. The phone
        then sends `update` calls as the user drags the virtual
        stick. Mirrors the desktop's `location.joystick.start` RPC.

        Forwards every Joystick state change through the RPC event
        channel so the desktop GUI updates its JoystickVM in real
        time — i.e. the desktop window mirrors what the phone is
        doing instead of being stuck on a stale snapshot.
        """
        from .joystick import JoystickController
        udid = _resolve_udid(req.udid)
        sess = await manager.session_for(udid)
        loc = await manager.location_for(udid)
        # Cancel any other movement before taking over.
        for runner_attr in ("navigator", "walker"):
            runner = getattr(sess, runner_attr, None)
            if runner is not None:
                try:
                    await runner.stop()
                except Exception:
                    pass
                setattr(sess, runner_attr, None)
        # If there's already a joystick, stop it first.
        if sess.joystick is not None:
            try:
                await sess.joystick.stop()
            except Exception:
                pass
            sess.joystick = None

        async def _joystick_emit(method: str, status) -> None:
            payload = status.to_json() if hasattr(status, "to_json") else dict(status)
            payload["udid"] = udid
            await _emit(method, payload)

        ctrl = JoystickController(
            location=loc,
            origin=(req.lat, req.lng),
            on_event=_joystick_emit,
        )
        await manager.set_joystick(udid, ctrl)
        ctrl.start()
        await _emit("event.state_changed", {
            "udid": udid, "mode": "joystick",
            **ctrl.status().to_json(),
        })
        return {"ok": True, "udid": udid, **ctrl.status().to_json()}

    @app.post("/api/phone/joystick/update")
    async def phone_joystick_update(
        req: JoystickUpdateRequest, _token: str = Depends(require_token)
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid)
        sess = await manager.session_for(udid)
        if sess.joystick is None:
            raise HTTPException(
                status_code=409,
                detail="no_joystick_session — call /joystick/start first",
            )
        await sess.joystick.update(req.heading_deg, req.speed_mps)
        return sess.joystick.status().to_json()

    @app.post("/api/phone/random_walk")
    async def phone_random_walk(
        req: RandomWalkRequest, _token: str = Depends(require_token)
    ) -> dict[str, Any]:
        """Start a random walk centred on (center_lat, center_lng) with
        the given radius. Walker drifts inside that circle until
        `/stop` is called or another action takes over."""
        from .random_walker import RandomWalker
        if not (0 < req.radius_m <= 50_000):
            raise HTTPException(status_code=400,
                                detail="radius_m must be 0 < r <= 50000")
        if req.min_speed_mps <= 0 or req.max_speed_mps < req.min_speed_mps:
            raise HTTPException(status_code=400,
                                detail="invalid speed band")

        udid = _resolve_udid(req.udid)
        sess = await manager.session_for(udid)
        loc = await manager.location_for(udid)
        # Cancel competing motion first.
        for runner_attr in ("navigator", "joystick"):
            runner = getattr(sess, runner_attr, None)
            if runner is not None:
                try:
                    await runner.stop()
                except Exception:
                    pass
                setattr(sess, runner_attr, None)
        if sess.walker is not None:
            try:
                await sess.walker.stop()
            except Exception:
                pass
            sess.walker = None

        async def _walker_emit(method: str, status) -> None:
            payload = status.to_json() if hasattr(status, "to_json") else dict(status)
            payload["udid"] = udid
            await _emit(method, payload)

        walker = RandomWalker(
            location=loc,
            center=(req.center_lat, req.center_lng),
            radius_m=req.radius_m,
            min_speed_mps=req.min_speed_mps,
            max_speed_mps=req.max_speed_mps,
            on_event=_walker_emit,
        )
        await manager.set_walker(udid, walker)
        walker.start()
        await _emit("event.state_changed", {
            "udid": udid, "mode": "random_walk",
            **walker.status().to_json(),
        })
        return {"ok": True, "udid": udid, **walker.status().to_json()}

    @app.get("/api/phone/geocode")
    async def phone_geocode(
        q: str, _token: str = Depends(require_token)
    ) -> list[dict[str, Any]]:
        """Proxy to OpenStreetMap Nominatim. Phone has no good way
        to do mDNS / search itself — sending the query through the
        Mac means we get a single User-Agent / rate-limit identity
        for both desktop and phone usage."""
        if not q.strip():
            return []
        async with httpx.AsyncClient(timeout=8.0) as client:
            r = await client.get(
                "https://nominatim.openstreetmap.org/search",
                params={"q": q, "format": "json", "limit": 8},
                headers={"User-Agent": "LociiGhost/1.0 phone-control"},
            )
            r.raise_for_status()
            results = r.json()
        return [
            {
                "name": item.get("display_name", ""),
                "lat": float(item["lat"]),
                "lng": float(item["lon"]),
            }
            for item in results
        ]

    # ---- Static files / phone HTML ----

    @app.get("/", include_in_schema=False)
    async def root() -> RedirectResponse:
        return RedirectResponse(url="/phone")

    @app.get("/phone", response_class=HTMLResponse, include_in_schema=False)
    async def phone_html() -> FileResponse:
        return FileResponse(static_dir / "phone.html",
                            media_type="text/html; charset=utf-8")

    if static_dir.is_dir():
        app.mount("/static", StaticFiles(directory=static_dir), name="static")

    return app


# ── Server lifecycle ──────────────────────────────────────────────


def _pick_free_port(candidates: list[int]) -> Optional[int]:
    """Return the first port in `candidates` we can actually bind on
    0.0.0.0. Returns None if every candidate is occupied — caller
    logs and continues without the HTTP server in that case."""
    for p in candidates:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", p))
        except OSError:
            log.info("port %d in use; trying next", p)
            s.close()
            continue
        s.close()
        return p
    return None


async def run_http_server(
    manager: DeviceManager,
    osrm: OsrmClient,
    *,
    port: Optional[int] = None,
    rpc_server: Optional[Any] = None,
) -> None:
    """Long-running task — runs the HTTP server until cancelled.
    Spawned by `__main__._run` alongside the RPC server. If `port`
    is None we walk `PORT_CANDIDATES` and use the first free one,
    so a stale M-LocWarp Electron backend on 8777 doesn't block us
    from coming up at all."""
    candidates = [port] if port is not None else PORT_CANDIDATES
    bound_port = _pick_free_port(candidates)
    if bound_port is None:
        log.error(
            "phone-control HTTP server: no free port among %s — disabled",
            candidates,
        )
        return

    app = create_http_app(manager, osrm,
                          bound_port=bound_port, rpc_server=rpc_server)
    config = uvicorn.Config(
        app,
        host="0.0.0.0",
        port=bound_port,
        log_level="warning",
        access_log=False,         # noisy and we have our own request logging
        loop="asyncio",
        lifespan="off",           # we own the lifecycle
    )
    server = uvicorn.Server(config)
    log.info("phone-control HTTP server starting on 0.0.0.0:%d", bound_port)
    try:
        await server.serve()
    except asyncio.CancelledError:
        log.info("phone-control HTTP server cancelled; shutting down")
        server.should_exit = True
        raise
    except Exception:
        log.exception("phone-control HTTP server crashed")
        raise
