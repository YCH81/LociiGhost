from __future__ import annotations

import asyncio
import inspect
import json
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

log = logging.getLogger(__name__)

JSONRPC_VERSION = "2.0"

# Standard JSON-RPC 2.0 errors
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

Handler = Callable[..., Any | Awaitable[Any]]


@dataclass
class RpcError(Exception):
    code: int
    message: str
    data: Any = None

    def __str__(self) -> str:
        return f"[{self.code}] {self.message}"


class Connection:
    """A single client connection. Pushes events out as line-delimited JSON."""

    def __init__(self, writer: asyncio.StreamWriter) -> None:
        self._writer = writer
        self._lock = asyncio.Lock()
        self._closed = False

    @property
    def closed(self) -> bool:
        return self._closed or self._writer.is_closing()

    async def send(self, payload: dict[str, Any]) -> None:
        if self.closed:
            return
        line = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        async with self._lock:
            try:
                self._writer.write(line)
                await self._writer.drain()
            except (ConnectionResetError, BrokenPipeError):
                self._closed = True

    async def push_event(self, method: str, params: dict[str, Any] | None = None) -> None:
        """Send a JSON-RPC notification (no `id`)."""
        msg: dict[str, Any] = {"jsonrpc": JSONRPC_VERSION, "method": method}
        if params is not None:
            msg["params"] = params
        await self.send(msg)


class RpcServer:
    """
    Idle-friendly Unix-socket JSON-RPC 2.0 server.

    Design rules (see plan, "性能與散熱"):
    - No polling, no heartbeat, no watchdog.
    - When no client connected and no in-flight request, the loop is parked
      in accept() and consumes 0% CPU.
    - Notifications (events) are pushed only when state changes -- never
      on a fixed timer.
    """

    def __init__(self, socket_path: str) -> None:
        self.socket_path = socket_path
        self._handlers: dict[str, Handler] = {}
        self._server: asyncio.AbstractServer | None = None
        self._connections: set[Connection] = set()

    def register(self, method: str, handler: Handler) -> None:
        self._handlers[method] = handler

    def method(self, name: str) -> Callable[[Handler], Handler]:
        def decorator(fn: Handler) -> Handler:
            self.register(name, fn)
            return fn
        return decorator

    async def broadcast_event(self, method: str, params: dict[str, Any] | None = None) -> None:
        """Push a notification to every connected client."""
        if not self._connections:
            return
        await asyncio.gather(
            *(c.push_event(method, params) for c in list(self._connections) if not c.closed),
            return_exceptions=True,
        )

    async def serve_forever(self) -> None:
        import os
        import socket as _socket
        import stat

        # If a previous daemon's socket file is sitting on the path, decide
        # whether it's a stale leftover (safe to remove) or a live process
        # we'd be clobbering (refuse to start).
        if os.path.exists(self.socket_path):
            try:
                st = os.stat(self.socket_path)
            except OSError:
                st = None
            if st is not None and stat.S_ISSOCK(st.st_mode):
                if _is_socket_alive(self.socket_path):
                    raise RuntimeError(
                        f"Another locwarpd is already listening on {self.socket_path}; "
                        f"refusing to clobber its socket."
                    )
            try:
                os.unlink(self.socket_path)
            except FileNotFoundError:
                pass

        self._server = await asyncio.start_unix_server(
            self._handle_client,
            path=self.socket_path,
        )

        # When this daemon was launched via `sudo`, the socket file is created
        # owned by root. The unprivileged GUI app then cannot connect to a
        # mode-0600 socket it doesn't own. Chown the file back to the invoking
        # user so the app can talk to us.
        sudo_uid = os.environ.get("SUDO_UID")
        sudo_gid = os.environ.get("SUDO_GID")
        if sudo_uid is not None and os.geteuid() == 0:
            try:
                os.chown(
                    self.socket_path,
                    int(sudo_uid),
                    int(sudo_gid) if sudo_gid is not None else -1,
                )
            except Exception:
                log.exception("chown of socket to SUDO_UID failed")

        os.chmod(self.socket_path, 0o600)

        log.info("RPC server listening on %s", self.socket_path)
        async with self._server:
            await self._server.serve_forever()

    async def _handle_client(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        conn = Connection(writer)
        self._connections.add(conn)
        peer = writer.get_extra_info("peername") or writer.get_extra_info("sockname")
        log.debug("client connected: %s", peer)
        try:
            while not conn.closed:
                line = await reader.readline()
                if not line:
                    break
                await self._dispatch_line(conn, line)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("client handler crashed")
        finally:
            self._connections.discard(conn)
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
            log.debug("client disconnected: %s", peer)

    async def _dispatch_line(self, conn: Connection, line: bytes) -> None:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            await conn.send(_error_response(None, PARSE_ERROR, "Parse error"))
            return

        if not isinstance(request, dict):
            await conn.send(_error_response(None, INVALID_REQUEST, "Invalid Request"))
            return

        request_id = request.get("id")
        method = request.get("method")
        params = request.get("params") or {}

        if not isinstance(method, str):
            await conn.send(_error_response(request_id, INVALID_REQUEST, "Invalid Request"))
            return

        handler = self._handlers.get(method)
        if handler is None:
            if request_id is not None:
                await conn.send(_error_response(request_id, METHOD_NOT_FOUND, f"Method not found: {method}"))
            return

        try:
            result = await _call_handler(handler, params, conn)
        except RpcError as e:
            if request_id is not None:
                await conn.send(_error_response(request_id, e.code, e.message, e.data))
            return
        except TypeError as e:
            if request_id is not None:
                await conn.send(_error_response(request_id, INVALID_PARAMS, f"Invalid params: {e}"))
            return
        except Exception as e:
            log.exception("handler error: %s", method)
            if request_id is not None:
                await conn.send(_error_response(request_id, INTERNAL_ERROR, f"Internal error: {e}"))
            return

        # Notifications (no id) get no response, even on success.
        if request_id is not None:
            await conn.send({"jsonrpc": JSONRPC_VERSION, "id": request_id, "result": result})


async def _call_handler(handler: Handler, params: dict[str, Any], conn: Connection) -> Any:
    sig = inspect.signature(handler)
    kwargs: dict[str, Any] = {}
    for name in sig.parameters:
        if name == "conn":
            kwargs["conn"] = conn
        elif name in params:
            kwargs[name] = params[name]
    result = handler(**kwargs)
    if inspect.isawaitable(result):
        result = await result
    return result


def _error_response(req_id: Any, code: int, message: str, data: Any = None) -> dict[str, Any]:
    err: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": JSONRPC_VERSION, "id": req_id, "error": err}


def _is_socket_alive(path: str) -> bool:
    """True if a Unix socket at *path* has a live process accepting on it.

    Used to distinguish a stale socket file (a previous daemon crashed
    without cleaning up) from a real running daemon. A simple `connect`
    is enough -- if the kernel returns ECONNREFUSED or ENOENT, no one
    is home and we can safely unlink and rebind. If connect succeeds,
    someone is.
    """
    import socket as _socket

    try:
        s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    except OSError:
        return False
    try:
        s.settimeout(0.5)
        s.connect(path)
        return True
    except (FileNotFoundError, ConnectionRefusedError, OSError):
        return False
    finally:
        try:
            s.close()
        except Exception:
            pass
