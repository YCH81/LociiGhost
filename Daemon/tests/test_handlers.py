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
from contextlib import asynccontextmanager
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from locwarpd import handlers
from locwarpd.device_manager import DeviceManager
from locwarpd.routing import OsrmClient
from locwarpd.rpc import RpcServer

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
    line = await reader.readline()
    writer.close()
    return json.loads(line)


@pytest.mark.asyncio
async def test_device_list_no_devices():
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=[])):
        async with serving_with_handlers() as (sock, _, _):
            resp = await _call(sock, "device.list")
            assert resp["result"] == []


@pytest.mark.asyncio
async def test_device_list_one_device():
    raw = MagicMock(serial="ABC", connection_type="USB")
    lockdown = MagicMock(all_values={"DeviceName": "Test", "ProductVersion": "17.4.1"})
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=[raw])), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=lockdown)):
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

    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=[raw])), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=lockdown)):
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
