"""End-to-end tests for the RPC handler layer.

Builds a real RpcServer + DeviceManager, but mocks the lockdown layer so
we don't need an iPhone. Verifies:

  * device.list returns a JSON array even when no devices are present
  * device.connect / device.disconnect produce an event.device_changed
  * location.teleport rejects out-of-range coords
  * location.teleport on a disconnected device returns the right error code
"""

from __future__ import annotations

import asyncio
import json
import os
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from lociighostd import handlers
from lociighostd.device_manager import DeviceManager
from lociighostd.routing import OsrmClient
from lociighostd.rpc import RpcServer

pytestmark = pytest.mark.asyncio(loop_scope="function")


@asynccontextmanager
async def serving_with_handlers():
    with tempfile.TemporaryDirectory() as tmp:
        sock = str(Path(tmp) / "h.sock")
        server = RpcServer(sock)
        manager = DeviceManager()
        osrm = OsrmClient()
        handlers.register(server, manager, osrm)

        task = asyncio.create_task(server.serve_forever())
        for _ in range(50):
            if os.path.exists(sock):
                break
            await asyncio.sleep(0.01)
        try:
            yield sock, manager, server
        finally:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass


async def _call(sock: str, method: str, **params):
    reader, writer = await asyncio.open_unix_connection(sock)
    payload = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params:
        payload["params"] = params
    writer.write((json.dumps(payload) + "\n").encode())
    await writer.drain()
    # The connection also carries broadcast events, and a handler that
    # emits one before replying would otherwise have its event read as
    # the reply. Skip anything without our id.
    while True:
        line = await reader.readline()
        if not line:
            writer.close()
            raise AssertionError(f"connection closed before {method} replied")
        message = json.loads(line)
        if message.get("id") is not None:
            writer.close()
            return message


@pytest.mark.asyncio
async def test_device_list_no_devices():
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _, _):
            resp = await _call(sock, "device.list")
            assert resp["result"] == []


@pytest.mark.asyncio
async def test_device_list_one_device():
    raw = MagicMock(serial="ABC", connection_type="USB")
    lockdown = MagicMock(all_values={"DeviceName": "Test", "ProductVersion": "17.4.1"})
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[raw])), \
         patch("lociighostd.device_manager.create_using_usbmux", AsyncMock(return_value=lockdown)):
        async with serving_with_handlers() as (sock, _, _):
            resp = await _call(sock, "device.list")
            assert len(resp["result"]) == 1
            assert resp["result"][0]["udid"] == "ABC"
            assert resp["result"][0]["transport"] == "usb"


@pytest.mark.asyncio
async def test_location_teleport_invalid_lat():
    async with serving_with_handlers() as (sock, _, _):
        resp = await _call(sock, "location.teleport", udid="X", lat=200.0, lng=0.0)
        assert "error" in resp
        assert "Invalid latitude" in resp["error"]["message"]


@pytest.mark.asyncio
async def test_location_teleport_unknown_device():
    async with serving_with_handlers() as (sock, _, _):
        resp = await _call(sock, "location.teleport", udid="ghost", lat=25.0, lng=121.0)
        assert "error" in resp
        # -32002 == DEVICE_NOT_CONNECTED
        assert resp["error"]["code"] == -32002


@pytest.mark.asyncio
async def test_device_connect_disconnect_emits_events():
    raw = MagicMock(serial="X", connection_type="USB")
    lockdown = MagicMock(all_values={"DeviceName": "T", "ProductVersion": "16.5"})

    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[raw])), \
         patch("lociighostd.device_manager.create_using_usbmux", AsyncMock(return_value=lockdown)):
        async with serving_with_handlers() as (sock, _, _):
            reader, writer = await asyncio.open_unix_connection(sock)

            # connect
            writer.write(b'{"jsonrpc":"2.0","id":1,"method":"device.connect","params":{"udid":"X"}}\n')
            await writer.drain()

            seen_events: list[dict] = []
            seen_response: dict | None = None
            for _ in range(5):
                line = await asyncio.wait_for(reader.readline(), timeout=2.0)
                obj = json.loads(line)
                if "id" in obj:
                    seen_response = obj
                else:
                    seen_events.append(obj)
                if seen_response is not None and seen_events:
                    break

            assert seen_response is not None
            assert seen_response["result"]["udid"] == "X"
            assert any(
                ev["method"] == "event.device_changed"
                and ev["params"]["status"] == "connected"
                for ev in seen_events
            )

            # disconnect
            writer.write(b'{"jsonrpc":"2.0","id":2,"method":"device.disconnect","params":{"udid":"X"}}\n')
            await writer.drain()

            seen_events_d: list[dict] = []
            disc_response: dict | None = None
            for _ in range(5):
                line = await asyncio.wait_for(reader.readline(), timeout=2.0)
                obj = json.loads(line)
                if "id" in obj:
                    disc_response = obj
                else:
                    seen_events_d.append(obj)
                if disc_response is not None and seen_events_d:
                    break

            assert disc_response is not None
            assert disc_response["result"]["disconnected"] is True
            assert any(
                ev["method"] == "event.device_changed"
                and ev["params"]["status"] == "disconnected"
                for ev in seen_events_d
            )

            writer.close()


# ── location.flower_estimate (v1.17) ────────────────────────────────


@pytest.mark.asyncio
async def test_flower_estimate_needs_no_device():
    """The settings panel is open before anything is connected. An
    estimate that needed a phone would be an estimate nobody sees."""
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _manager, _server):
            reply = await _call(
                sock, "location.flower_estimate",
                points=[{"lat": 25.0339, "lng": 121.5645}],
                settings={"segments": 4, "laps": 1.0, "radius_m": 50, "rounds": 2},
                origin_lat=25.0339, origin_lng=121.5645,
            )
    result = reply["result"]
    assert result["points"] == 1
    assert result["rounds"] == 2
    assert result["vertices_per_point"] == 4
    assert result["steps"] == 2 * 5
    assert result["seconds"] > 0


@pytest.mark.asyncio
async def test_flower_estimate_accepts_bare_pairs_too():
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _manager, _server):
            reply = await _call(sock, "location.flower_estimate",
                                points=[[25.0339, 121.5645]])
    assert reply["result"]["points"] == 1


@pytest.mark.asyncio
async def test_flower_estimate_rejects_an_empty_waypoint_list():
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _manager, _server):
            reply = await _call(sock, "location.flower_estimate", points=[])
    assert "error" in reply


@pytest.mark.asyncio
async def test_flower_estimate_rejects_an_off_the_planet_waypoint():
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _manager, _server):
            reply = await _call(sock, "location.flower_estimate",
                                points=[{"lat": 91.0, "lng": 0.0}])
    assert "error" in reply


@pytest.mark.asyncio
async def test_flower_on_a_disconnected_device_is_an_error_not_a_crash():
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _manager, _server):
            reply = await _call(sock, "location.flower",
                                udid="nope",
                                points=[{"lat": 25.0, "lng": 121.0}])
    assert "error" in reply


# ── The cooldown gate (v1.17) ───────────────────────────────────────


@pytest.mark.asyncio
async def test_cooldown_is_off_until_it_is_set():
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _manager, _server):
            reply = await _call(sock, "settings.cooldown")
    assert reply["result"]["enabled"] is False


@pytest.mark.asyncio
async def test_setting_the_cooldown_reads_back():
    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _manager, _server):
            await _call(sock, "settings.cooldown", policy={
                "enabled": True,
                "max_speed_kmh": 80,
                "minimum_gap_s": 3,
                "steps": [{"distance_km": 10, "wait_minutes": 5}],
            })
            reply = await _call(sock, "settings.cooldown")
    result = reply["result"]
    assert result["enabled"] is True
    assert result["max_speed_kmh"] == 80
    assert result["steps"] == [{"distance_km": 10.0, "wait_minutes": 5.0}]


@pytest.mark.asyncio
async def test_the_gate_refuses_a_jump_and_says_how_long_is_left():
    """The reply carries the numbers, not only a sentence: the app
    shows a countdown, and parsing seconds out of a message string is
    a client that breaks when the wording changes."""
    from lociighostd.location_service import LocationService

    fake = MagicMock(spec=LocationService)
    fake.last_lat_lng = (25.0339, 121.5645)
    # The service stamps this from the monotonic clock, so the test has
    # to as well — against `0.0`, "elapsed" is the machine's uptime and
    # every jump looks long overdue.
    fake._last_set_at = time.monotonic()
    fake.set = AsyncMock()

    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, manager, _server):
            manager.location_for = AsyncMock(return_value=fake)
            await _call(sock, "settings.cooldown",
                        policy={"enabled": True, "max_speed_kmh": 5})
            # 133 km at 5 km/h is more than a day; nothing has elapsed.
            reply = await _call(sock, "location.teleport",
                                udid="whatever", lat=24.1477, lng=120.6736)

    assert reply["error"]["code"] == -32007
    data = reply["error"]["data"]
    assert data["remaining_s"] > 3600
    assert data["distance_m"] > 100_000
    fake.set.assert_not_awaited()


@pytest.mark.asyncio
async def test_the_gate_lets_the_first_position_of_a_session_through():
    """Nothing to be implausible relative to, and a blocked first
    teleport is indistinguishable from a broken app."""
    from lociighostd.location_service import LocationService

    fake = MagicMock(spec=LocationService)
    fake.last_lat_lng = None
    fake._last_set_at = 0.0
    fake.set = AsyncMock()

    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, manager, _server):
            manager.location_for = AsyncMock(return_value=fake)
            await _call(sock, "settings.cooldown",
                        policy={"enabled": True, "max_speed_kmh": 1})
            reply = await _call(sock, "location.teleport",
                                udid="whatever", lat=24.1477, lng=120.6736)

    assert reply["result"]["ok"] is True
    fake.set.assert_awaited()


# ── Groups (v1.17) ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_a_group_teleport_moves_every_member():
    from lociighostd.location_service import LocationService

    services = {}
    for udid in ("lead", "second", "third"):
        fake = MagicMock(spec=LocationService)
        fake.last_lat_lng = None
        fake._last_set_at = time.monotonic()
        fake.set = AsyncMock()
        services[udid] = fake

    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, manager, _server):
            manager.location_for = AsyncMock(side_effect=lambda u: services[u])
            reply = await _call(sock, "location.teleport",
                                udid="lead", lat=25.0, lng=121.0,
                                group={"udids": ["lead", "second", "third"]})

    assert reply["result"]["ok"] is True
    for udid, fake in services.items():
        fake.set.assert_awaited_once()
        assert fake.set.await_args.args == (25.0, 121.0), f"{udid} went somewhere else"


@pytest.mark.asyncio
async def test_a_disconnected_member_is_skipped_not_fatal():
    """One phone unplugged shouldn't refuse the run for the other two —
    but it must not pass silently either."""
    from lociighostd import errors as err
    from lociighostd.location_service import LocationService

    lead = MagicMock(spec=LocationService)
    lead.last_lat_lng = None
    lead._last_set_at = time.monotonic()
    lead.set = AsyncMock()

    async def location_for(udid):
        if udid == "lead":
            return lead
        raise err.device_not_connected(udid)

    events: list[dict] = []

    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, manager, server):
            manager.location_for = AsyncMock(side_effect=location_for)
            original = server.broadcast_event

            async def capture(method, params):
                events.append({"method": method, **params})
                await original(method, params)

            server.broadcast_event = capture
            reply = await _call(sock, "location.teleport",
                                udid="lead", lat=25.0, lng=121.0,
                                group={"udids": ["lead", "ghost"]})

    assert reply["result"]["ok"] is True
    lead.set.assert_awaited_once()
    assert any(e["method"] == "event.group_changed" and e.get("skipped") == ["ghost"]
               for e in events), events


@pytest.mark.asyncio
async def test_a_group_of_one_takes_the_ordinary_path():
    from lociighostd.location_service import LocationService

    lead = MagicMock(spec=LocationService)
    lead.last_lat_lng = None
    lead._last_set_at = time.monotonic()
    lead.set = AsyncMock()

    with patch("lociighostd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, manager, _server):
            manager.location_for = AsyncMock(return_value=lead)
            reply = await _call(sock, "location.teleport",
                                udid="lead", lat=25.0, lng=121.0,
                                group={"udids": ["lead"]})

    assert reply["result"]["ok"] is True
    lead.set.assert_awaited_once()
