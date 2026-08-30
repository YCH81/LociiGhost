"""Phone-control attack surface.

The HTTP listener binds 0.0.0.0 because that is the point of phone
control, so everything here is reachable by anyone on the same WiFi.
Regression cover for the v1.15.2 audit findings X4, X5 and X10.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from lociighostd.device_manager import DeviceManager
from lociighostd.http_server import create_http_app
from lociighostd.routing import OsrmClient

from ._fakes import FakeLocation, make_session

UDID = "SEC-UDID"


@pytest.fixture
def app_client():
    mgr = DeviceManager()
    loc = FakeLocation()
    loc.last_lat_lng = (25.0, 121.0)
    make_session(mgr, UDID, location=loc)
    app = create_http_app(mgr, OsrmClient(), bound_port=8779)
    return TestClient(app, base_url="http://127.0.0.1:8779",
                      client=("127.0.0.1", 51234)), app


def _authed(client):
    pin = client.get("/api/phone/info").json()["pin"]
    token = client.post("/api/phone/auth", json={"pin": pin}).json()["token"]
    client.headers.update({"X-Lociighost-Token": token})
    return client


# ── X4: PIN strength, pairing window, lockout ──────────────────────

def test_pin_is_eight_digits(app_client):
    client, _ = app_client
    pin = client.get("/api/phone/info").json()["pin"]
    assert len(pin) == 8 and pin.isdigit()


def test_pin_is_rejected_before_the_user_opens_pairing(app_client):
    """A daemon that has been up for hours must not still be accepting
    PIN guesses. /api/phone/info — which only the Mac can reach — is
    what opens the window."""
    client, _ = app_client
    resp = client.post("/api/phone/auth", json={"pin": "12345678"})
    assert resp.status_code == 409
    assert resp.json()["detail"] == "pairing_closed"


def test_pairing_window_mints_a_fresh_pin(app_client):
    client, app = app_client
    first = client.get("/api/phone/info").json()["pin"]
    # Expire the window as if ten minutes had passed.
    app.state.phone_auth.pairing_open_until = 0.0
    second = client.get("/api/phone/info").json()["pin"]
    assert first != second, "a PIN left on screen must not stay live"


def test_repeated_wrong_pins_lock_the_peer_out(app_client):
    client, app = app_client
    client.get("/api/phone/info")          # open pairing
    auth = app.state.phone_auth
    codes = []
    for _ in range(auth.LOCKOUT_AFTER_FAILURES + 1):
        codes.append(client.post("/api/phone/auth",
                                 json={"pin": "00000000"}).status_code)
    assert 429 in codes, f"never locked out: {codes}"
    resp = client.post("/api/phone/auth", json={"pin": "00000000"})
    assert resp.status_code == 429
    assert "Retry-After" in resp.headers


def test_a_correct_pin_still_works_and_clears_failures(app_client):
    client, app = app_client
    pin = client.get("/api/phone/info").json()["pin"]
    client.post("/api/phone/auth", json={"pin": "00000000"})
    resp = client.post("/api/phone/auth", json={"pin": pin})
    assert resp.status_code == 200
    assert app.state.phone_auth.lockout_remaining("127.0.0.1") == 0


def test_sustained_attack_rotates_the_pin_and_closes_pairing(app_client):
    client, app = app_client
    auth = app.state.phone_auth
    client.get("/api/phone/info")
    before = auth.pin
    for _ in range(auth.GLOBAL_FAILURES_BEFORE_ROTATE):
        # Vary the peer so per-IP lockout doesn't stop us reaching the
        # global counter — a botnet would look like this.
        auth._record_failure(f"10.0.0.{_ % 200}")
    assert auth.pin != before
    assert not auth.pairing_is_open


# ── X5: DNS rebinding / cross-origin ───────────────────────────────

def test_a_named_host_header_is_refused(app_client):
    """DNS rebinding needs a hostNAME. `_is_localhost` checks the
    connecting IP, and the user's own browser connects from 127.0.0.1,
    so before this guard a page on evil.com that re-pointed itself at
    127.0.0.1 could read the PIN straight out of /api/phone/info."""
    client, _ = app_client
    resp = client.get("/api/phone/info", headers={"Host": "evil.com"})
    assert resp.status_code == 421
    assert "pin" not in resp.text


@pytest.mark.parametrize("host", ["127.0.0.1:8779", "192.168.1.42:8779",
                                  "localhost:8779", "[::1]:8779"])
def test_ip_literal_hosts_are_accepted(app_client, host):
    client, _ = app_client
    resp = client.get("/api/phone/info", headers={"Host": host})
    assert resp.status_code == 200


def test_cross_origin_api_calls_are_refused(app_client):
    client, _ = app_client
    resp = client.get("/api/phone/info",
                      headers={"Origin": "http://evil.example"})
    assert resp.status_code == 403


def test_same_origin_calls_pass(app_client):
    client, _ = app_client
    resp = client.get("/api/phone/info",
                      headers={"Origin": "http://127.0.0.1:8779"})
    assert resp.status_code == 200


# ── X10: input validation on the HTTP side ─────────────────────────

@pytest.mark.parametrize("payload", [
    {"lat": 200.0, "lng": 0.0},
    {"lat": 0.0, "lng": 400.0},
    {"lat": 1e308, "lng": 0.0},
])
def test_teleport_rejects_impossible_coordinates(app_client, payload):
    """The RPC side has always called _validate_coord; the phone
    endpoints never did."""
    client, _ = app_client
    client = _authed(client)
    assert client.post("/api/phone/teleport", json=payload).status_code == 422


@pytest.mark.parametrize("literal", ["Infinity", "-Infinity", "NaN"])
def test_teleport_rejects_non_finite_json_literals(app_client, literal):
    """Python's json module happily parses these; pydantic used to let
    them through as bare floats. A NaN reaching the navigator makes
    _seg_len NaN, after which the advance loop can never make progress
    and the route hangs with no error. Sent as raw bytes because the
    JSON encoder refuses to produce them."""
    client, _ = app_client
    client = _authed(client)
    resp = client.post(
        "/api/phone/teleport",
        content=f'{{"lat": {literal}, "lng": 0.0}}'.encode(),
        headers={"Content-Type": "application/json"},
    )
    assert resp.status_code == 422


def test_random_walk_rejects_an_absurd_radius(app_client):
    client, _ = app_client
    client = _authed(client)
    resp = client.post("/api/phone/random_walk",
                       json={"center_lat": 25.0, "center_lng": 121.0,
                             "radius_m": 1e12})
    assert resp.status_code == 422


def test_multistop_rejects_an_unbounded_stop_list(app_client):
    client, _ = app_client
    client = _authed(client)
    stops = [{"lat": 25.0, "lng": 121.0}] * 5000
    resp = client.post("/api/phone/multistop", json={"stops": stops})
    assert resp.status_code == 422


def test_joystick_rejects_a_wild_speed(app_client):
    client, _ = app_client
    client = _authed(client)
    resp = client.post("/api/phone/joystick/update",
                       json={"heading_deg": 0.0, "speed_mps": 1e9})
    assert resp.status_code == 422
