"""Phone-control HTTP API.

Regression cover for the v1.15.2 audit findings L1, L2 and L3: the
phone endpoints diverged from their RPC equivalents in ways the Mac
had no way to notice.

  L1  navigate / multistop stopped only `sess.navigator`, so a phone
      navigate on top of a Mac random walk left both tickers pushing.
  L2  every phone endpoint emitted "mode"; AppState reads "state" and
      returned early, so the desktop never learned the phone had
      stopped, paused or resumed.
  L3  restore cleared the simulation without stopping the mover, which
      re-armed it within a tick -- while returning ok: true.
"""
from __future__ import annotations

from typing import Any

import pytest
from fastapi.testclient import TestClient

from lociighostd.device_manager import DeviceManager
from lociighostd.http_server import create_http_app
from lociighostd.routing import OsrmClient, Route

from ._fakes import FakeLocation, FakeRunner, make_session

UDID = "PHONE-UDID"


class RecordingRpc:
    """Stands in for RpcServer, capturing broadcast events."""

    def __init__(self) -> None:
        self.events: list[tuple[str, dict[str, Any]]] = []

    async def broadcast_event(self, method: str, params: dict[str, Any]) -> None:
        self.events.append((method, params))

    def states(self) -> list[dict[str, Any]]:
        return [p for m, p in self.events if m == "event.state_changed"]


@pytest.fixture
def rig(monkeypatch):
    mgr = DeviceManager()
    loc = FakeLocation()
    # The phone has no map state of its own, so navigate routes from
    # the last coordinate the daemon successfully pushed.
    loc.last_lat_lng = (25.0, 121.0)
    sess = make_session(mgr, UDID, location=loc)
    rpc = RecordingRpc()
    osrm = OsrmClient()

    async def fake_route_through(waypoints, profile="driving", **kw):
        pts = [(float(a), float(b)) for a, b in waypoints]
        return Route(coordinates=pts, distance_m=100.0,
                     duration_s=10.0, profile=profile)

    monkeypatch.setattr(osrm, "route_through", fake_route_through)

    app = create_http_app(mgr, osrm, bound_port=8779, rpc_server=rpc)
    # base_url matters: the Host guard added for X5 rejects anything
    # that isn't an IP literal, which is precisely what makes DNS
    # rebinding impossible. TestClient's default "testserver" is a name.
    client = TestClient(app, base_url="http://127.0.0.1:8779",
                        client=("127.0.0.1", 51234))

    # Reading /info is what opens the pairing window (X4).
    pin = client.get("/api/phone/info").json()["pin"]
    token = client.post("/api/phone/auth", json={"pin": pin}).json()["token"]
    client.headers.update({"X-Lociighost-Token": token})
    return client, mgr, sess, loc, rpc


def test_rotate_pin_actually_rotates(rig):
    """X6: the endpoint called a method that doesn't exist, so every
    'Change PIN' 500'd and the old PIN stayed valid."""
    client, *_ = rig
    before = client.get("/api/phone/info").json()["pin"]
    resp = client.post("/api/phone/rotate")
    assert resp.status_code == 200
    after = resp.json()["pin"]
    assert after != before
    assert client.get("/api/phone/info").json()["pin"] == after


def test_navigate_stops_a_running_walker(rig):
    """L1: navigate only ever stopped the navigator."""
    client, mgr, sess, loc, _ = rig
    # Not started: TestClient owns the event loop, so a task can't be
    # created from this (synchronous) test body. Attaching the runner is
    # enough -- the endpoint is what has to notice and stop it.
    walker = FakeRunner("walker")
    sess.walker = walker

    resp = client.post("/api/phone/navigate",
                       json={"lat": 25.05, "lng": 121.55})
    assert resp.status_code == 200, resp.text
    assert sess.walker is None, "random walker survived a phone navigate"
    assert walker.stopped
    assert sess.navigator is not None


def test_multistop_stops_a_running_joystick(rig):
    client, mgr, sess, loc, _ = rig
    joy = FakeRunner("joystick")
    sess.joystick = joy

    resp = client.post("/api/phone/multistop",
                       json={"stops": [{"lat": 25.05, "lng": 121.55},
                                       {"lat": 25.06, "lng": 121.56}]})
    assert resp.status_code == 200, resp.text
    assert sess.joystick is None and joy.stopped
    assert sess.navigator is not None


def test_restore_stops_the_mover_before_clearing(rig):
    """L3: clearing while the navigator still ran meant the 'real GPS'
    lasted less than one tick."""
    client, mgr, sess, loc, _ = rig
    nav = FakeRunner("nav")
    sess.navigator = nav

    resp = client.post("/api/phone/restore", json={})
    assert resp.status_code == 200
    assert sess.navigator is None and nav.stopped
    assert loc.cleared == 1


@pytest.mark.parametrize(
    "path, body, expected",
    [
        ("/api/phone/stop", {}, "stopped"),
        ("/api/phone/restore", {}, "stopped"),
        ("/api/phone/pause", {}, "paused"),
        ("/api/phone/resume", {}, "moving"),
    ],
)
def test_every_state_event_carries_a_state_key(rig, path, body, expected):
    """L2: AppState.applyStateEvent keys off "state" and bailed out
    when only "mode" was present."""
    client, mgr, sess, loc, rpc = rig
    resp = client.post(path, json=body)
    assert resp.status_code == 200, resp.text
    states = rpc.states()
    assert states, f"{path} broadcast no state_changed"
    assert states[-1].get("state") == expected


def test_teleport_emits_one_state_event_not_one_per_mover(rig):
    """The old loop emitted inside the per-runner body."""
    client, mgr, sess, loc, rpc = rig
    sess.navigator = FakeRunner("nav")
    sess.walker = FakeRunner("walker")

    resp = client.post("/api/phone/teleport",
                       json={"lat": 25.0, "lng": 121.0})
    assert resp.status_code == 200
    assert len(rpc.states()) == 1
    assert rpc.states()[0]["state"] == "stopped"
    assert loc.calls[-1] == (25.0, 121.0)


def test_teleport_without_a_mover_emits_nothing(rig):
    client, mgr, sess, loc, rpc = rig
    client.post("/api/phone/teleport", json={"lat": 25.0, "lng": 121.0})
    assert rpc.states() == []


# ── Flower mode from the phone (v1.17) ──────────────────────────────


def test_flower_orbits_the_last_position_when_no_stops_are_given(rig):
    client, mgr, sess, loc, rpc = rig
    resp = client.post("/api/phone/flower",
                       json={"settings": {"segments": 4, "radius_m": 30}})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["ok"] is True
    assert body["points"] == 1
    assert body["total_steps"] == 5          # 1 arrival + 4 vertices
    assert sess.flower is not None


def test_flower_takes_explicit_stops(rig):
    client, mgr, sess, loc, rpc = rig
    resp = client.post("/api/phone/flower", json={
        "stops": [{"lat": 25.1, "lng": 121.5}, {"lat": 25.2, "lng": 121.6}],
        "settings": {"segments": 3, "laps": 1, "rounds": 2},
    })
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["points"] == 2
    assert body["rounds"] == 2
    assert body["total_steps"] == 2 * 2 * 4  # rounds x points x (1 + 3)
    assert [m for m, p in rpc.events if m == "event.state_changed"]


def test_flower_stops_a_running_walker(rig):
    """Same contract as every other phone mode: one mover at a time."""
    client, mgr, sess, loc, _ = rig
    walker = FakeRunner("walker")
    sess.walker = walker

    resp = client.post("/api/phone/flower", json={})
    assert resp.status_code == 200, resp.text
    assert sess.walker is None and walker.stopped
    assert sess.flower is not None


def test_flower_without_an_origin_says_what_to_do(rig):
    client, mgr, sess, loc, _ = rig
    loc.last_lat_lng = None
    resp = client.post("/api/phone/flower", json={})
    assert resp.status_code == 400
    assert "no_origin" in resp.json()["detail"]


# ── The cooldown gate covers the phone too (v1.17) ──────────────────


def test_the_cooldown_gate_applies_to_phone_teleports(rig):
    """The gate used to live in the RPC handlers' closure, so a user
    who had turned it on could still jump anywhere from their phone.
    It lives on the DeviceManager now, which is what both entry points
    read."""
    import time as _time
    from lociighostd.cooldown import CooldownPolicy

    client, mgr, sess, loc, _ = rig
    loc.last_lat_lng = (25.0, 121.0)
    loc._last_set_at = _time.monotonic()
    mgr.cooldown_policy = CooldownPolicy(enabled=True, max_speed_kmh=5)

    resp = client.post("/api/phone/teleport", json={"lat": 24.1477, "lng": 120.6736})
    assert resp.status_code == 429, resp.text
    detail = resp.json()["detail"]
    assert detail["error"] == "cooldown_active"
    assert detail["remaining_s"] > 3600
    assert detail["distance_m"] > 100_000
    # …and the phone did not move the device.
    assert loc.calls == []


def test_a_disabled_cooldown_lets_the_phone_through(rig):
    client, mgr, sess, loc, _ = rig
    resp = client.post("/api/phone/teleport", json={"lat": 24.1477, "lng": 120.6736})
    assert resp.status_code == 200, resp.text
    assert loc.calls[-1] == (24.1477, 120.6736)


def test_the_gate_also_covers_the_phones_random_walk(rig):
    import time as _time
    from lociighostd.cooldown import CooldownPolicy

    client, mgr, sess, loc, _ = rig
    loc.last_lat_lng = (25.0, 121.0)
    loc._last_set_at = _time.monotonic()
    mgr.cooldown_policy = CooldownPolicy(enabled=True, max_speed_kmh=5)

    resp = client.post("/api/phone/random_walk", json={
        "center_lat": 24.1477, "center_lng": 120.6736, "radius_m": 200,
    })
    assert resp.status_code == 429, resp.text
    assert sess.walker is None
