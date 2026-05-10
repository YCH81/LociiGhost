from __future__ import annotations

import asyncio
import json
import os
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path

import pytest

from locwarpd.rpc import RpcError, RpcServer

pytestmark = pytest.mark.asyncio(loop_scope="function")


@asynccontextmanager
async def running_server(setup):
    """Start an RpcServer on a temporary socket and yield (socket_path, server)."""
    with tempfile.TemporaryDirectory() as tmp:
        sock = str(Path(tmp) / "test.sock")
        server = RpcServer(sock)
        setup(server)
        task = asyncio.create_task(server.serve_forever())
        # Wait until the socket is bound.
        for _ in range(50):
            if os.path.exists(sock):
                break
            await asyncio.sleep(0.01)
        assert os.path.exists(sock), "socket did not appear"
        try:
            yield sock, server
        finally:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass


async def _connect(sock: str) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    return await asyncio.open_unix_connection(sock)


async def _request(writer: asyncio.StreamWriter, reader: asyncio.StreamReader, payload: dict) -> dict | None:
    writer.write((json.dumps(payload) + "\n").encode())
    await writer.drain()
    if "id" not in payload:
        return None
    line = await reader.readline()
    return json.loads(line)


@pytest.mark.asyncio
async def test_ping_round_trip():
    def setup(server: RpcServer) -> None:
        @server.method("ping")
        async def ping():
            return {"pong": True}

    async with running_server(setup) as (sock, _):
        reader, writer = await _connect(sock)
        try:
            resp = await _request(writer, reader, {"jsonrpc": "2.0", "id": 1, "method": "ping"})
            assert resp == {"jsonrpc": "2.0", "id": 1, "result": {"pong": True}}
        finally:
            writer.close()


@pytest.mark.asyncio
async def test_method_not_found():
    async with running_server(lambda s: None) as (sock, _):
        reader, writer = await _connect(sock)
        try:
            resp = await _request(writer, reader, {"jsonrpc": "2.0", "id": 9, "method": "nope"})
            assert resp is not None
            assert resp["error"]["code"] == -32601
        finally:
            writer.close()


@pytest.mark.asyncio
async def test_parse_error():
    async with running_server(lambda s: None) as (sock, _):
        reader, writer = await _connect(sock)
        try:
            writer.write(b"not-valid-json\n")
            await writer.drain()
            line = await reader.readline()
            resp = json.loads(line)
            assert resp["error"]["code"] == -32700
            assert resp["id"] is None
        finally:
            writer.close()


@pytest.mark.asyncio
async def test_invalid_params_synchronous_handler():
    def setup(server: RpcServer) -> None:
        @server.method("add")
        def add(a: int, b: int) -> int:
            return a + b

    async with running_server(setup) as (sock, _):
        reader, writer = await _connect(sock)
        try:
            ok = await _request(writer, reader, {"jsonrpc": "2.0", "id": 1, "method": "add", "params": {"a": 2, "b": 3}})
            assert ok["result"] == 5

            bad = await _request(writer, reader, {"jsonrpc": "2.0", "id": 2, "method": "add", "params": {"a": 1}})
            assert bad["error"]["code"] == -32602
        finally:
            writer.close()


@pytest.mark.asyncio
async def test_notification_returns_no_response():
    received: list[str] = []

    def setup(server: RpcServer) -> None:
        @server.method("note")
        async def note(msg: str) -> None:
            received.append(msg)

    async with running_server(setup) as (sock, _):
        reader, writer = await _connect(sock)
        try:
            # No `id` => notification, server must not reply.
            writer.write(b'{"jsonrpc":"2.0","method":"note","params":{"msg":"hi"}}\n')
            await writer.drain()
            try:
                line = await asyncio.wait_for(reader.readline(), timeout=0.2)
            except asyncio.TimeoutError:
                line = b""
            assert line == b""
        finally:
            writer.close()
        # Allow the server task to drain the message.
        await asyncio.sleep(0.05)
        assert received == ["hi"]


@pytest.mark.asyncio
async def test_handler_can_raise_rpc_error():
    def setup(server: RpcServer) -> None:
        @server.method("boom")
        async def boom():
            raise RpcError(code=-32000, message="domain error", data={"hint": "x"})

    async with running_server(setup) as (sock, _):
        reader, writer = await _connect(sock)
        try:
            resp = await _request(writer, reader, {"jsonrpc": "2.0", "id": 1, "method": "boom"})
            assert resp["error"]["code"] == -32000
            assert resp["error"]["message"] == "domain error"
            assert resp["error"]["data"] == {"hint": "x"}
        finally:
            writer.close()


@pytest.mark.asyncio
async def test_event_broadcast():
    async with running_server(lambda s: None) as (sock, server):
        reader, writer = await _connect(sock)
        try:
            await asyncio.sleep(0.05)  # let server register the connection
            await server.broadcast_event("event.tick", {"n": 1})
            line = await asyncio.wait_for(reader.readline(), timeout=1.0)
            evt = json.loads(line)
            assert evt == {"jsonrpc": "2.0", "method": "event.tick", "params": {"n": 1}}
            assert "id" not in evt
        finally:
            writer.close()
