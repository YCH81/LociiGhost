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
import ipaddress
import logging
import secrets
import socket
import time
from pathlib import Path
from typing import Annotated, Any, Optional

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
from fastapi.exceptions import RequestValidationError
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    JSONResponse,
    RedirectResponse,
)
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field

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


class _PhoneSession:
    """One mobile-web tab. Each authenticated phone gets its own
    `_PhoneSession` — own token, own targeted iPhone UDID, own
    last-seen heartbeat. Lets two people on two phones drive two
    different iPhones independently without fighting for the
    same `controlling_udid`."""

    def __init__(self, token: str) -> None:
        self.token: str = token
        self.controlling_udid: Optional[str] = None
        self.last_seen: float = time.monotonic()
        self.created_at: float = time.monotonic()

    def touch(self) -> None:
        self.last_seen = time.monotonic()

    def is_stale(self, timeout_s: float) -> bool:
        return (time.monotonic() - self.last_seen) > timeout_s


class _PhoneAuth:
    """Multi-session phone-auth manager (v1.8).

    Shared PIN gates auth, but each successful PIN exchange
    mints a NEW token + `_PhoneSession`. The desktop's lockout
    overlay reads the *union* of `controlling_udid` across all
    sessions — Mac on iPhone A is locked only if at least one
    phone session is currently driving A.

    Daemon-wide state (pin, sync_mode) lives here; per-tab
    state (token, targeted device, last_seen) lives on
    `_PhoneSession`."""

    # Phone polls /state every 3 s. If a session hasn't been
    # heard from in this many seconds we evict it — handles
    # tabs closed without explicit logout / lost network /
    # device sleep.
    #
    # v1.9.2: bumped 15 → 300 seconds (5 min). iOS Safari
    # aggressively suspends background tabs to save battery —
    # `setInterval` gets throttled or paused outright the moment
    # the user swipes to another app (a Pokémon GO catch, Maps,
    # an incoming message). At 15s the daemon was reaping
    # sessions mid-suspend, so returning to the LociiGhost tab
    # gave a 401 on the next poll and the page flipped to
    # "disconnected". 5 minutes covers most "I'm in the game
    # for a while" scenarios while still cleaning up genuinely
    # abandoned tabs eventually.
    SESSION_IDLE_TIMEOUT_S = 300.0

    # ── Brute-force resistance (v1.15.2 audit X4) ─────────────
    # The HTTP listener is on 0.0.0.0 because that is the whole
    # point of phone control, so the PIN is the only thing between
    # anyone on the same cafe/office/dorm WiFi and full control of
    # the user's iPhone location. Six digits with no rate limit is
    # about forty minutes at a conservative 200 req/s. Three
    # independent changes fix that:
    #
    #   * eight digits instead of six (100x the space),
    #   * a per-IP lockout with exponential backoff, so an attacker
    #     gets a handful of guesses per minute rather than
    #     thousands per second,
    #   * a pairing WINDOW: the PIN is only accepted while the user
    #     is actually looking at the pairing sheet. Already-issued
    #     tokens keep working indefinitely, so a paired phone is
    #     unaffected; a stranger only has a target during the few
    #     minutes the user is pairing.
    PIN_DIGITS = 8
    PAIRING_WINDOW_S = 600.0          # 10 minutes
    LOCKOUT_AFTER_FAILURES = 5
    LOCKOUT_BASE_S = 30.0
    LOCKOUT_MAX_S = 900.0
    # Total failures across all peers before we assume we're being
    # attacked and rotate the PIN out from under it.
    GLOBAL_FAILURES_BEFORE_ROTATE = 25

    def _fresh_pin(self) -> str:
        upper = 10 ** self.PIN_DIGITS
        return str(secrets.randbelow(upper)).zfill(self.PIN_DIGITS)

    def __init__(self) -> None:
        self.pin: str = ""
        self.created_at: float = time.monotonic()
        # Pairing is closed until the desktop asks for the PIN.
        self.pairing_open_until: float = 0.0
        # peer ip -> (consecutive failures, locked-out-until monotonic)
        self._failures: dict[str, tuple[int, float]] = {}
        self._global_failures: int = 0
        # Active sessions, keyed by token. Pretty small dict —
        # typical user has ≤ 2 phones, so O(n) scans below are
        # fine.
        self.sessions: dict[str, _PhoneSession] = {}
        # Mac-side opt-in: lets Mac + phones drive concurrently.
        self.sync_mode: bool = False

    # ── PIN / token lifecycle ─────────────────────────────────

    def rotate_pin(self) -> None:
        """Rotate the PIN. Does NOT touch existing sessions —
        a kicked phone needs the new PIN to reconnect, but
        sessions already authenticated stay valid until they
        explicitly log out or go stale."""
        self.pin = self._fresh_pin()
        self.created_at = time.monotonic()
        self._failures.clear()
        self._global_failures = 0

    # ── Pairing window ────────────────────────────────────────

    def open_pairing(self) -> None:
        """Start (or extend) the window in which the PIN is accepted.

        Called when the desktop reads `/api/phone/info` — i.e. when
        the user has the pairing sheet in front of them. A fresh PIN
        is minted each time the window opens from closed, so a PIN
        that was on screen an hour ago is not still live.
        """
        now = time.monotonic()
        if now >= self.pairing_open_until:
            self.rotate_pin()
        self.pairing_open_until = now + self.PAIRING_WINDOW_S

    @property
    def pairing_is_open(self) -> bool:
        return time.monotonic() < self.pairing_open_until

    # ── Lockout ───────────────────────────────────────────────

    def lockout_remaining(self, peer: str) -> float:
        """Seconds this peer must wait before its next attempt."""
        count, until = self._failures.get(peer, (0, 0.0))
        del count
        return max(0.0, until - time.monotonic())

    def _record_failure(self, peer: str) -> None:
        count, _ = self._failures.get(peer, (0, 0.0))
        count += 1
        wait = 0.0
        if count >= self.LOCKOUT_AFTER_FAILURES:
            over = count - self.LOCKOUT_AFTER_FAILURES
            wait = min(self.LOCKOUT_MAX_S, self.LOCKOUT_BASE_S * (2 ** over))
        self._failures[peer] = (count, time.monotonic() + wait)
        self._global_failures += 1
        if wait:
            log.warning("phone auth: %s locked out for %.0fs after %d "
                        "failed PINs", peer, wait, count)
        if self._global_failures >= self.GLOBAL_FAILURES_BEFORE_ROTATE:
            log.warning("phone auth: %d failed PIN attempts overall — "
                        "rotating the PIN and closing pairing",
                        self._global_failures)
            self.rotate_pin()
            self.pairing_open_until = 0.0

    def authenticate(self, pin: str, peer: str = "?") -> Optional[_PhoneSession]:
        """Verify PIN; if good, mint a fresh session and return
        it. Returns None on bad PIN — caller raises 403.

        `peer` is the requesting IP, used for the lockout counter.
        Callers must check `lockout_remaining(peer)` first and
        `pairing_is_open` — this method enforces both anyway so a
        new caller can't forget.
        """
        if not self.pairing_is_open or not self.pin:
            log.warning("phone auth: PIN attempt from %s while pairing "
                        "is closed", peer)
            return None
        if self.lockout_remaining(peer) > 0:
            return None
        if not secrets.compare_digest(pin, self.pin):
            self._record_failure(peer)
            return None
        self._failures.pop(peer, None)
        self._global_failures = 0
        token = secrets.token_hex(16)
        session = _PhoneSession(token)
        self.sessions[token] = session
        return session

    def get_session(self, token: Optional[str]) -> Optional[_PhoneSession]:
        if not token:
            return None
        return self.sessions.get(token)

    def remove_session(self, token: Optional[str]) -> bool:
        """Remove the session that owns `token`. Returns True
        if a session was actually removed (caller decides
        whether to broadcast)."""
        if not token:
            return False
        return self.sessions.pop(token, None) is not None

    def clear_all(self) -> int:
        """Kick every session (force-logout from Mac). Returns
        the count that got cleared."""
        count = len(self.sessions)
        self.sessions.clear()
        return count

    # ── Aggregate queries (used by Mac side) ──────────────────

    def is_any_active(self) -> bool:
        return bool(self.sessions)

    def controlling_udids(self) -> list[str]:
        """De-duped list of UDIDs currently being driven by
        some phone session. Used in `event.phone_session`
        broadcasts so the Mac knows which iPhone rows to lock."""
        seen: list[str] = []
        for s in self.sessions.values():
            if s.controlling_udid and s.controlling_udid not in seen:
                seen.append(s.controlling_udid)
        return seen

    def sweep_stale(self) -> int:
        """Remove sessions that haven't been touched within
        the idle timeout. Returns count removed (caller
        broadcasts if > 0)."""
        cutoff = self.SESSION_IDLE_TIMEOUT_S
        stale = [t for t, s in self.sessions.items() if s.is_stale(cutoff)]
        for t in stale:
            self.sessions.pop(t, None)
        return len(stale)


# ── Helpers ───────────────────────────────────────────────────────


def _is_localhost(request: Request) -> bool:
    """True iff the HTTP request reached us over loopback. Used to
    gate `/api/phone/info` and `/api/phone/rotate` so the URL and
    fresh-PIN endpoints are NEVER exposed to the LAN — only the
    desktop GUI (running on this same Mac) can fetch them."""
    host = (request.client.host if request.client else "") or ""
    return host in ("127.0.0.1", "::1", "localhost")


def _looks_like_ip_literal(host: str) -> bool:
    """True if `host` is a bare IPv4/IPv6 address rather than a name.

    Used by the Host-header guard: DNS rebinding requires a name, so
    refusing names is the whole defence. See the middleware in
    `create_http_app` (v1.15.2 audit X5).
    """
    if not host:
        return False
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        # Link-local IPv6 carries a zone id: fe80::1%en0
        if "%" in host:
            try:
                ipaddress.ip_address(host.split("%", 1)[0])
                return True
            except ValueError:
                return False
        return False


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
    # v1.15.2 audit (X4): widened 6 -> 8 digits. Accepts either length
    # so a phone page cached from an older daemon still gets a clean
    # 403 rather than an unhelpful 422.
    pin: str = Field(min_length=6, max_length=8, pattern=r"^\d{6,8}$")


# v1.15.2 audit (X10): every field below used to be a bare `float` or
# an unbounded list, and the phone endpoints — unlike their RPC
# counterparts — never called `_validate_coord`. An authenticated phone
# (or anyone who got past the PIN) could send lat=1e308, a 1e12-metre
# random-walk radius, or five thousand stops. `allow_inf_nan=False`
# matters as much as the ranges: Python's json module accepts
# `Infinity`, and a NaN reaching the navigator makes `_seg_len` NaN,
# after which the advance loop can never make progress and the route
# hangs forever with no error.

_STRICT = ConfigDict(allow_inf_nan=False, extra="forbid")

Latitude = Annotated[float, Field(ge=-90.0, le=90.0)]
Longitude = Annotated[float, Field(ge=-180.0, le=180.0)]
# 200 m/s is ~720 km/h; anything faster is a typo or an attack, and
# the daemon's own profile presets top out around 11 m/s.
SpeedMps = Annotated[float, Field(gt=0.0, le=200.0)]
Profile = Annotated[str, Field(pattern=r"^(walking|cycling|driving)$")]


class TeleportRequest(BaseModel):
    model_config = _STRICT
    lat: Latitude
    lng: Longitude
    udid: Optional[str] = None


class NavigateRequest(BaseModel):
    model_config = _STRICT
    lat: Latitude
    lng: Longitude
    profile: Profile = "driving"
    speed: Optional[SpeedMps] = None
    udid: Optional[str] = None


class StopPoint(BaseModel):
    model_config = _STRICT
    lat: Latitude
    lng: Longitude


class MultiStopRequest(BaseModel):
    model_config = _STRICT
    # A phone screen can't usefully stage more than a handful; the cap
    # is really about not letting one request fan out into an unbounded
    # (and, with Google Directions, billable) routing job.
    stops: list[StopPoint] = Field(min_length=1, max_length=100)
    profile: Profile = "driving"
    speed: Optional[SpeedMps] = None
    udid: Optional[str] = None


class UdidOnlyRequest(BaseModel):
    udid: Optional[str] = None


class JoystickStartRequest(BaseModel):
    model_config = _STRICT
    lat: Latitude
    lng: Longitude
    udid: Optional[str] = None


class JoystickUpdateRequest(BaseModel):
    model_config = _STRICT
    heading_deg: Annotated[float, Field(ge=-360.0, le=360.0)]
    # 0 parks the stick, so this one is ge rather than gt.
    speed_mps: Annotated[float, Field(ge=0.0, le=200.0)]
    udid: Optional[str] = None


class RandomWalkRequest(BaseModel):
    model_config = _STRICT
    center_lat: Latitude
    center_lng: Longitude
    radius_m: Annotated[float, Field(gt=0.0, le=50_000.0)]
    min_speed_mps: SpeedMps = 0.8
    max_speed_mps: SpeedMps = 1.6
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
    # Hand the auth instance to the socket-side RPC server so
    # handlers.py can expose phone.session / phone.force_logout
    # RPCs that read + mutate the same state the FastAPI side
    # owns. Without this they'd be two independent ideas of "is
    # the phone logged in?".
    if rpc_server is not None:
        setattr(rpc_server, "phone_auth", auth)
    static_dir = Path(__file__).parent / "static"
    app = FastAPI(title="LociiGhost Phone Control")

    @app.exception_handler(RequestValidationError)
    async def _validation_error(request: Request,
                                exc: RequestValidationError) -> JSONResponse:
        """Return a clean 422 without echoing the offending input.

        v1.15.2 audit (X10): FastAPI's default handler puts the input
        value into the response body, and json.dumps cannot serialise
        Infinity or NaN — so the exact values the new bounds exist to
        reject turned what should be a 422 into an unhandled 500 with a
        traceback. Reporting only the field names is also one less
        place attacker-controlled bytes get reflected back.
        """
        fields = sorted({
            ".".join(str(part) for part in err.get("loc", ())[1:])
            for err in exc.errors()
        })
        return JSONResponse(
            {"detail": "invalid_request", "fields": fields},
            status_code=422,
        )

    @app.middleware("http")
    async def _guard_host_and_origin(request: Request, call_next):
        """Block DNS rebinding and cross-site calls.

        v1.15.2 audit (X5). `_is_localhost` tests the *connecting IP*,
        and a browser running on the user's own Mac connects from
        127.0.0.1 — so a page on evil.com that re-points its own name
        at 127.0.0.1 (classic DNS rebinding) reached `/api/phone/info`
        as same-origin, read the PIN out of the response, and had full
        control of the iPhone. The page never had to be trusted; the
        user only had to visit it.

        Rebinding needs a hostNAME, so requiring the Host header to be
        an IP literal (or localhost) removes the attack. The Origin
        check then covers ordinary cross-site scripting attempts.
        """
        host = (request.headers.get("host") or "").rsplit(":", 1)[0]
        host = host.strip("[]").lower()          # IPv6 literal brackets
        allowed_host = (
            host in ("", "localhost", "127.0.0.1", "::1")
            or _looks_like_ip_literal(host)
        )
        if not allowed_host:
            log.warning("rejecting request with non-IP Host header %r "
                        "(possible DNS rebinding)", host)
            return JSONResponse({"detail": "bad_host"}, status_code=421)

        origin = request.headers.get("origin")
        if origin and request.url.path.startswith("/api/"):
            expected = f"{request.url.scheme}://{request.headers.get('host', '')}"
            if origin != expected:
                log.warning("rejecting cross-origin API call from %r", origin)
                return JSONResponse({"detail": "bad_origin"}, status_code=403)
        return await call_next(request)

    # Token dependency — looks up the session that owns the
    # token and touches its heartbeat. Raises 401 if no session
    # matches (token expired / phone got kicked). Returns the
    # session so handlers can read its `controlling_udid` (or
    # write to it via `_resolve_udid`).
    async def require_session(
        request: Request,
        x_lociighost_token: Optional[str] = Header(default=None),
        t: Optional[str] = Query(default=None),
    ) -> _PhoneSession:
        supplied = x_lociighost_token or t
        session = auth.get_session(supplied)
        if session is None:
            raise HTTPException(status_code=401, detail="invalid_token")
        session.touch()
        return session

    # Back-compat alias for endpoints that don't care about the
    # session payload, only that the request is authenticated.
    async def require_token(
        session: _PhoneSession = Depends(require_session),
    ) -> str:
        return session.token

    # ---- Auth / pairing ----

    @app.post("/api/phone/auth")
    async def phone_auth(req: AuthRequest, request: Request) -> dict[str, Any]:
        # Each successful PIN exchange mints a FRESH token + a
        # FRESH `_PhoneSession`. Multiple phones can authenticate
        # independently — each one ends up with its own session
        # and can target a different iPhone.
        peer = (request.client.host if request.client else "") or "?"
        # v1.15.2 audit (X4): tell a locked-out or too-late caller
        # apart from a wrong PIN, so the phone UI can say something
        # useful and an attacker learns nothing they couldn't time
        # anyway.
        wait = auth.lockout_remaining(peer)
        if wait > 0:
            raise HTTPException(
                status_code=429, detail=f"locked_out:{int(wait) + 1}",
                headers={"Retry-After": str(int(wait) + 1)},
            )
        if not auth.pairing_is_open:
            raise HTTPException(status_code=409, detail="pairing_closed")
        session = auth.authenticate(req.pin, peer=peer)
        if session is None:
            raise HTTPException(status_code=403, detail="bad_pin")
        # Mac listens for `event.phone_session` to update its
        # lockout overlay. udids list = de-duped controlled
        # devices across ALL sessions (this new one starts with
        # controlling_udid=None until the user takes an action).
        await _emit("event.phone_session", {
            "active": auth.is_any_active(),
            "udids": auth.controlling_udids(),
        })
        return {"token": session.token}

    @app.get("/api/phone/sync_mode")
    async def phone_sync_mode_get(_token: str = Depends(require_token)) -> dict[str, Any]:
        return {"sync": auth.sync_mode}

    class SyncModeRequest(BaseModel):
        sync: bool
    @app.post("/api/phone/sync_mode")
    async def phone_sync_mode_set(
        req: SyncModeRequest, _token: str = Depends(require_token)
    ) -> dict[str, Any]:
        """Toggle the Mac/phone simultaneous-control flag. The
        Mac's lockout overlay reads the same flag (via the
        socket-side `phone.session` RPC + `event.sync_mode`
        broadcast) so flipping here flips on the Mac too."""
        was = auth.sync_mode
        auth.sync_mode = bool(req.sync)
        if was != auth.sync_mode:
            await _emit("event.sync_mode", {"sync": auth.sync_mode})
        return {"sync": auth.sync_mode}

    class TargetRequest(BaseModel):
        udid: Optional[str] = None

    @app.post("/api/phone/target")
    async def phone_target(
        req: TargetRequest,
        session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        """Phone tab explicitly picks (or unsets) which iPhone
        it's driving. Updates the calling session's
        `controlling_udid` and broadcasts so the Mac's lockout
        flips even before the phone has fired any other action.
        Pass `udid: null` to revert to Auto-pick-first-connected."""
        new_target = req.udid or None
        if session.controlling_udid != new_target:
            session.controlling_udid = new_target
            await _emit("event.phone_session", {
                "active": auth.is_any_active(),
                "udids": auth.controlling_udids(),
            })
        return {
            "ok": True,
            "udid": session.controlling_udid,
            "udids": auth.controlling_udids(),
        }

    @app.post("/api/phone/logout")
    async def phone_logout(
        session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        """Phone-initiated sign-out. Removes ONLY the calling
        tab's session — other phones keep going. PIN is NOT
        rotated (a second phone might still be using it). If
        this was the last session, Mac will see active=False.
        """
        auth.remove_session(session.token)
        await _emit("event.phone_session", {
            "active": auth.is_any_active(),
            "udids": auth.controlling_udids(),
        })
        return {"ok": True}

    @app.get("/api/phone/info")
    async def phone_info(request: Request) -> dict[str, Any]:
        if not _is_localhost(request):
            raise HTTPException(status_code=404)
        # v1.15.2 audit (X4): reading the PIN is what the desktop does
        # when the user opens the pairing sheet, so it is the honest
        # signal for "the user is pairing right now". Opening the
        # window here mints a fresh PIN if the previous window had
        # expired, which means a PIN that was on screen an hour ago is
        # no longer live. Already-issued tokens are untouched, so a
        # phone paired this morning keeps working.
        auth.open_pairing()
        ip = _get_lan_ip() or "127.0.0.1"
        return {
            "url": f"http://{ip}:{bound_port}/phone",
            "pin": auth.pin,
            "lan_ip": ip,
            "port": bound_port,
            "pairing_seconds_left": int(
                max(0.0, auth.pairing_open_until - time.monotonic())),
        }

    @app.post("/api/phone/rotate")
    async def phone_rotate(request: Request) -> dict[str, Any]:
        if not _is_localhost(request):
            raise HTTPException(status_code=404)
        # v1.15.2 audit (X6): this used to call `auth.rotate()`, which
        # does not exist -> AttributeError -> 500 on every attempt. The
        # Mac ignored the status code, so "Change PIN" silently did
        # nothing and the old PIN stayed valid for the daemon's whole
        # lifetime. Rotating now also drops live sessions, which is
        # what the button's label ("kick my phones") actually promises.
        auth.rotate_pin()
        auth.clear_all()
        # Pressing "Change PIN" means the user is about to re-pair.
        auth.pairing_open_until = time.monotonic() + auth.PAIRING_WINDOW_S
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

            # Active flower run — the phone draws the ring the device
            # is currently orbiting, same idea as the walk circle.
            flower = getattr(sess, "flower", None)
            if flower is not None:
                status = flower.status()
                centers = getattr(flower, "_centers", None) or []
                if 0 <= status.point_index < len(centers):
                    center = centers[status.point_index]
                    entry["flower_center_lat"] = center[0]
                    entry["flower_center_lng"] = center[1]
                    entry["flower_radius_m"] = flower._settings.radius_m
                entry["flower_step"] = status.step_index
                entry["flower_total_steps"] = status.total_steps
                entry["mode"] = "flower"

            # Active joystick — just a flag; the map dot is enough.
            if sess.joystick is not None:
                entry["mode"] = "joystick"

            out.append(entry)
        return {"devices": out}

    # ---- Actions (mutate) ----

    def _resolve_udid(
        supplied: Optional[str],
        session: Optional[_PhoneSession] = None,
    ) -> str:
        """Pick which device an action targets. Caller-supplied
        UDID wins; otherwise the first connected device. Raises
        400 if nothing's connected so the phone doesn't silently
        fail.

        When called from a phone endpoint, pass the requesting
        `session` so we can stamp its `controlling_udid`. That
        per-session field is the source of truth for the Mac's
        per-device lockout overlay — broadcasting on every
        change is what makes "phone A drives iPhone X; phone B
        drives iPhone Y" work in real time.
        """
        target: Optional[str] = None
        if supplied:
            target = supplied
        else:
            for udid, sess in manager._sessions.items():  # noqa: SLF001
                if sess.transport in ("usb", "network"):
                    target = udid
                    break
        if target is None:
            raise HTTPException(status_code=400, detail="no_device_connected")
        # Stamp the session that called us; emit a broadcast if
        # this changes the union of controlled UDIDs the Mac
        # cares about. `controlling_udids()` is recomputed AFTER
        # the assignment so the payload reflects the new state.
        if session is not None and session.controlling_udid != target:
            session.controlling_udid = target
            asyncio.create_task(_emit("event.phone_session", {
                "active": auth.is_any_active(),
                "udids": auth.controlling_udids(),
            }))
        return target

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
        req: TeleportRequest, session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid, session)
        loc = await manager.location_for(udid)
        # Cancel any in-flight mover before teleport — same semantics
        # as the desktop right-click "Teleport" path. v1.15.2 audit
        # (L4): one atomic stop instead of an unsynchronised loop, and
        # (L2) one event instead of one per stopped mover.
        if await manager.stop_all_movement(udid):
            # Tell the desktop the previous mode is over so it clears
            # its NavigationVM / RandomWalkVM / JoystickVM.
            # AppState.applyStateEvent keys off "state"; "mode" alone
            # was dropped on the floor, so the desktop stayed stuck on
            # "moving" forever. "stopped" rather than "idle" because
            # this is a user-driven cancel — "idle" means natural route
            # completion and starts the next lap on the Mac.
            await _emit("event.state_changed", {
                "udid": udid, "mode": "idle", "state": "stopped",
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
        req: UdidOnlyRequest, session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid, session)
        # v1.15.2 audit (L3): this used to clear the simulation while
        # leaving the mover running, so within one tick the navigator
        # pushed a fresh coordinate and the "real GPS" the user asked
        # for lasted well under a second — while the endpoint returned
        # ok: true. The RPC-side location.restore always did this; the
        # phone endpoint was the one that didn't.
        await manager.stop_all_movement(udid)
        loc = await manager.location_for(udid)
        await loc.clear()
        await _emit("event.state_changed", {
            "udid": udid, "mode": "restored", "state": "stopped",
        })
        return {"ok": True, "udid": udid}

    @app.post("/api/phone/stop")
    async def phone_stop(
        req: UdidOnlyRequest, session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid, session)
        await manager.stop_all_movement(udid)
        await _emit("event.state_changed", {
            "udid": udid, "mode": "idle", "state": "stopped",
        })
        return {"ok": True, "udid": udid}

    @app.post("/api/phone/pause")
    async def phone_pause(
        req: UdidOnlyRequest, session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        """Pause whichever movement runner is currently active
        (navigator / walker / joystick). No-op if none running."""
        udid = _resolve_udid(req.udid, session)
        sess = await manager.session_for(udid)
        for runner_attr in ("navigator", "walker", "joystick"):
            runner = getattr(sess, runner_attr, None)
            if runner is not None and hasattr(runner, "pause"):
                try:
                    await runner.pause()
                except Exception:
                    pass
        await _emit("event.state_changed",
                    {"udid": udid, "mode": "paused", "state": "paused"})
        return {"ok": True, "udid": udid}

    @app.post("/api/phone/resume")
    async def phone_resume(
        req: UdidOnlyRequest, session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid, session)
        sess = await manager.session_for(udid)
        for runner_attr in ("navigator", "walker", "joystick"):
            runner = getattr(sess, runner_attr, None)
            if runner is not None and hasattr(runner, "resume"):
                try:
                    await runner.resume()
                except Exception:
                    pass
        await _emit("event.state_changed",
                    {"udid": udid, "mode": "moving", "state": "moving"})
        return {"ok": True, "udid": udid}

    @app.post("/api/phone/navigate")
    async def phone_navigate(
        req: NavigateRequest, session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        # Phone-side navigate uses the same OSRM round-trip the
        # desktop does, then a one-shot Navigator. The phone doesn't
        # currently support multi-stop / loop / random-walk; teleport
        # and one-leg navigate cover the day-to-day "I'm not at the
        # Mac" use case and the rest can stay desktop-only for now.
        from .navigator import Navigator      # local import — heavy modules
        from .interpolator import route_length_m

        udid = _resolve_udid(req.udid, session)
        loc = await manager.location_for(udid)
        # v1.15.2 audit (L1): this used to stop only `sess.navigator`.
        # Starting a phone navigate while the Mac had a random walk (or
        # a joystick) running left BOTH tickers pushing into the same
        # location service, and the iPhone's GPS bounced between the
        # two sets of coordinates once a second. The stop happens
        # inside attach_runner below, atomically with the attach.

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
        await manager.attach_runner(udid, "navigator", nav)
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

    @app.post("/api/phone/multistop")
    async def phone_multistop(
        req: MultiStopRequest, session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        """Phone-side multi-stop nav. Takes 1..N waypoints (the
        phone built up via long-presses) and runs them as a single
        OSRM-routed trip via `route_through`. Origin is the
        device's last known simulated position (same rule as the
        single-leg endpoint), so the user must teleport once
        before the very first multi-stop in a session.
        """
        from .navigator import Navigator
        from .interpolator import route_length_m

        if not req.stops:
            raise HTTPException(status_code=400, detail="no_stops")

        udid = _resolve_udid(req.udid, session)
        loc = await manager.location_for(udid)
        # v1.15.2 audit (L1): see /api/phone/navigate — stopping only
        # the navigator left a walker or joystick competing for the
        # same iPhone. attach_runner below stops everything atomically.

        origin = getattr(loc, "last_lat_lng", None)
        if origin is None:
            raise HTTPException(
                status_code=400,
                detail=(
                    "no_origin: tap the map and Teleport once first, "
                    "so the iPhone has a starting position to route from."
                ),
            )

        waypoints = [origin] + [(s.lat, s.lng) for s in req.stops]
        try:
            route = await osrm.route_through(waypoints, profile=req.profile)
        except RoutingError as exc:
            raise HTTPException(status_code=502, detail=f"routing_failed: {exc}")

        speed_mps = req.speed
        if speed_mps is None:
            speed_mps = {
                "walking": 1.4, "cycling": 5.5, "driving": 11.1,
            }.get(req.profile, 11.1)

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
        await manager.attach_runner(udid, "navigator", nav)
        await _emit("event.state_changed", {
            "udid": udid, "mode": "navigate",
            **nav.status().to_json(),
        })
        return {
            "ok": True,
            "udid": udid,
            "distance_m": route_length_m(route.coordinates),
            "speed_mps": speed_mps,
            "stops": len(req.stops),
        }

    @app.post("/api/phone/joystick/start")
    async def phone_joystick_start(
        req: JoystickStartRequest, session: _PhoneSession = Depends(require_session),
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
        udid = _resolve_udid(req.udid, session)
        loc = await manager.location_for(udid)
        # Taking over from whatever else was moving happens inside
        # attach_runner, atomically with the attach (v1.15.2 audit L4).

        async def _joystick_emit(method: str, status) -> None:
            payload = status.to_json() if hasattr(status, "to_json") else dict(status)
            payload["udid"] = udid
            await _emit(method, payload)

        ctrl = JoystickController(
            location=loc,
            origin=(req.lat, req.lng),
            on_event=_joystick_emit,
        )
        await manager.attach_runner(udid, "joystick", ctrl)
        await _emit("event.state_changed", {
            "udid": udid, "mode": "joystick",
            **ctrl.status().to_json(),
        })
        return {"ok": True, "udid": udid, **ctrl.status().to_json()}

    @app.post("/api/phone/joystick/update")
    async def phone_joystick_update(
        req: JoystickUpdateRequest, session: _PhoneSession = Depends(require_session),
    ) -> dict[str, Any]:
        udid = _resolve_udid(req.udid, session)
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
        req: RandomWalkRequest, session: _PhoneSession = Depends(require_session),
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

        udid = _resolve_udid(req.udid, session)
        loc = await manager.location_for(udid)
        # Competing motion is stopped inside attach_runner, atomically
        # with the attach (v1.15.2 audit L4).

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
        await manager.attach_runner(udid, "walker", walker)
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
        # v1.15.2 audit (X16): Nominatim answers a rate-limited or
        # malformed request with a JSON *object* (or HTML), not a list.
        # Iterating that yielded strings, `item.get` raised
        # AttributeError, and the phone saw a 500 with a traceback in
        # the daemon log instead of "no results".
        if not isinstance(results, list):
            log.warning("geocode: unexpected response shape %s",
                        type(results).__name__)
            return []
        out: list[dict[str, Any]] = []
        for item in results:
            if not isinstance(item, dict):
                continue
            try:
                out.append({
                    "name": str(item.get("display_name", "")),
                    "lat": float(item["lat"]),
                    "lng": float(item["lon"]),
                })
            except (KeyError, TypeError, ValueError):
                continue
        return out

    # ---- Static files / phone HTML ----

    @app.get("/", include_in_schema=False)
    async def root() -> RedirectResponse:
        return RedirectResponse(url="/phone")

    @app.get("/phone", response_class=HTMLResponse, include_in_schema=False)
    async def phone_html() -> FileResponse:
        # Aggressive no-cache headers: iOS Safari LOVES to keep
        # static HTML around even after the page is closed, which
        # leaves users stranded on stale UI after we ship daemon
        # updates. `no-store` plus matching Pragma + Expires
        # covers Safari, Chrome, and the older WebViews.
        return FileResponse(
            static_dir / "phone.html",
            media_type="text/html; charset=utf-8",
            headers={
                "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
                "Pragma": "no-cache",
                "Expires": "0",
            },
        )

    if static_dir.is_dir():
        app.mount("/static", StaticFiles(directory=static_dir), name="static")

    # Zombie-session sweeper. Runs forever, every few seconds
    # checking whether `auth.active` is stale (phone tab closed
    # / network died / put to sleep with no explicit logout).
    # When it goes stale we flip active=False + broadcast so
    # the Mac's lockout overlay drops. Stashed onto app.state
    # so `run_http_server` can spawn it alongside uvicorn.
    async def phone_session_sweeper() -> None:
        while True:
            try:
                await asyncio.sleep(5)
                removed = auth.sweep_stale()
                if removed > 0:
                    await _emit("event.phone_session", {
                        "active": auth.is_any_active(),
                        "udids": auth.controlling_udids(),
                    })
                    log.info(
                        "phone session sweeper: evicted %d stale tab(s)",
                        removed,
                    )
            except asyncio.CancelledError:
                raise
            except Exception:
                log.debug("phone_session_sweeper iteration failed", exc_info=True)

    app.state.phone_session_sweeper = phone_session_sweeper
    # Exposed so tests (and any future introspection RPC) can reach the
    # auth state without reaching into the closure.
    app.state.phone_auth = auth

    return app


# ── Server lifecycle ──────────────────────────────────────────────


def _pick_free_port(candidates: list[int]) -> Optional[int]:
    """Return the first port in `candidates` we can bind on 0.0.0.0.

    Returns None if every candidate is occupied.

    v1.15.2 audit (X19): this is a probe — it binds, closes, and hands
    the port to uvicorn to bind again — so something else can take the
    port in between. The window is small but the consequence was
    silent: phone control just didn't come up, and the log said
    nothing about why. `run_http_server` now treats a bind failure as
    "try the next candidate" rather than as fatal, which closes the
    race in practice.
    """
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
    log.info(
        "phone-control HTTP server starting on 0.0.0.0:%d "
        "(reachable from the LAN; pairing is only open while the "
        "desktop's phone-control window has been opened)",
        bound_port,
    )
    # Spawn the zombie-session sweeper alongside the HTTP loop
    # so a phone tab that vanishes without logging out gets
    # auto-cleared and the Mac's lockout overlay drops. The
    # task is cancelled on shutdown via the finally below.
    sweeper_coro = getattr(app.state, "phone_session_sweeper", None)
    sweeper_task = (
        asyncio.create_task(sweeper_coro(), name="phone-session-sweeper")
        if sweeper_coro is not None else None
    )
    try:
        await server.serve()
    except asyncio.CancelledError:
        log.info("phone-control HTTP server cancelled; shutting down")
        server.should_exit = True
        raise
    except Exception:
        log.exception("phone-control HTTP server crashed")
        raise
    finally:
        if sweeper_task is not None and not sweeper_task.done():
            sweeper_task.cancel()
