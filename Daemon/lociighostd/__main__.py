"""lociighostd entry point.

Phase 0 scaffold: opens the Unix socket, registers a `ping` handler,
and idles waiting for clients. No polling, no background tasks.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys
from datetime import datetime, timezone

from . import __version__, handlers
from .device_manager import DeviceManager
from .paths import logs_dir, socket_path
from .routing import OsrmClient
from .rpc import RpcServer
from .usbmux_watcher import UsbmuxWatcher


def _build_server(socket: str, manager: DeviceManager, osrm: OsrmClient) -> RpcServer:
    server = RpcServer(socket)

    @server.method("ping")
    async def ping() -> dict[str, str]:
        return {
            "pong": True,
            "version": __version__,
            "time": datetime.now(timezone.utc).isoformat(),
        }

    @server.method("daemon.info")
    async def info() -> dict[str, object]:
        import os
        # `is_root` tells the GUI whether utun creation (iOS 17+ tunnel)
        # will succeed. Without it the GUI knows to surface its own
        # "authenticate as admin" prompt instead of waiting for the
        # tunnel call to fail at -32004 TUNNEL_FAILED.
        return {
            "version": __version__,
            "python": sys.version.split()[0],
            "socket": socket,
            "uid": os.geteuid(),
            "is_root": os.geteuid() == 0,
        }

    @server.method("daemon.shutdown")
    async def shutdown() -> dict[str, bool]:
        # Schedule graceful shutdown on the next event-loop iteration.
        loop = asyncio.get_running_loop()
        loop.call_soon(_request_shutdown)
        return {"ok": True}

    handlers.register(server, manager, osrm)

    return server


_shutdown_event: asyncio.Event | None = None


def _request_shutdown() -> None:
    if _shutdown_event is not None and not _shutdown_event.is_set():
        _shutdown_event.set()


async def _run(socket: str) -> int:
    global _shutdown_event
    _shutdown_event = asyncio.Event()
    manager = DeviceManager()
    osrm = OsrmClient()
    server = _build_server(socket, manager, osrm)

    # Push USB attach/detach events from usbmuxd straight to connected
    # clients, so the GUI can refresh its device list without polling.
    # On a detach we also tear down any active USB session, so the GUI
    # never sees a "ghost-connected" device after its cable is gone.
    async def on_usb_event(status: str, udid: str | None) -> None:
        if status == "detached":
            try:
                await manager.handle_usbmux_detached(udid)
            except Exception:
                logging.getLogger("lociighostd").exception("USB detach cleanup failed")
        params: dict[str, object] = {"status": status}
        if udid is not None:
            params["udid"] = udid
        await server.broadcast_event("event.device_changed", params)

    watcher = UsbmuxWatcher(on_usb_event)
    watcher.start()

    # Background health-check: every 5s probe each WiFi session's
    # peer IP. If an iPhone leaves the LAN (powered off, walked away,
    # joined a different SSID) the GUI flips to "disconnected" within
    # one tick instead of staying stuck on a stale "connected" badge
    # until the user tries an operation. 5s is the user-tested sweet
    # spot — quick enough that "I just put the phone on airplane mode"
    # reflects in the GUI before the user looks again, and the probe
    # itself is a single TCP-connect-and-close so the network cost is
    # trivial even at 1 iPhone × 5s.
    async def on_session_lost(udid: str) -> None:
        await server.broadcast_event("event.device_changed", {
            "udid": udid,
            "status": "disconnected",
            "reason": "wifi_health_check_failed",
        })

    health_task = asyncio.create_task(
        manager.run_health_check_loop(on_session_lost, interval=5.0),
        name="wifi-health-check",
    )

    # Phone-control HTTP server. Serves the mobile UI (`/phone`) and
    # the matching `/api/phone/*` endpoints on port 8777, bound to all
    # interfaces so a phone on the same WiFi can hit it. Auth is a
    # 6-digit PIN (regenerated on every daemon launch + on demand) +
    # a 32-hex token. Failures here don't take down the daemon — if
    # the port is already taken or some other process owns 8777 we
    # log it and continue without phone-control.
    from .http_server import run_http_server
    async def _http_supervisor() -> None:
        try:
            # Pass `server` so phone-side actions can broadcast the
            # same RPC event types the desktop GUI subscribes to —
            # otherwise a phone teleport / joystick / random-walk
            # change wouldn't reflect in the desktop window in real
            # time.
            await run_http_server(manager, osrm, rpc_server=server)
        except OSError as exc:
            logging.getLogger("lociighostd").warning(
                "phone-control HTTP server bind failed (%s); "
                "phone control will be unavailable this session", exc,
            )
        except asyncio.CancelledError:
            raise
        except Exception:
            logging.getLogger("lociighostd").exception(
                "phone-control HTTP server crashed"
            )
    http_task = asyncio.create_task(_http_supervisor(), name="phone-http")

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _request_shutdown)

    serve_task = asyncio.create_task(server.serve_forever(), name="rpc-serve")
    shutdown_task = asyncio.create_task(_shutdown_event.wait(), name="shutdown-wait")

    done, pending = await asyncio.wait(
        {serve_task, shutdown_task},
        return_when=asyncio.FIRST_COMPLETED,
    )

    # Cancel the WiFi health-check loop. Doing this before USB watcher
    # stop so a probe-then-disconnect can't race the teardown.
    health_task.cancel()
    try:
        await health_task
    except (asyncio.CancelledError, Exception):
        pass

    # Same for the phone-control HTTP server — cancel and let
    # uvicorn shut down its sockets cleanly. We've already given any
    # in-flight phone request its chance to finish via the
    # FIRST_COMPLETED wait above; if a request is still mid-flight
    # at this point it gets a connection drop.
    http_task.cancel()
    try:
        await http_task
    except (asyncio.CancelledError, Exception):
        pass

    # Stop the USB watcher first so it doesn't fire events into a server
    # that's already tearing down.
    try:
        await watcher.stop()
    except Exception:
        logging.getLogger("lociighostd").exception("watcher.stop on shutdown failed")

    # Tear down all device sessions cleanly so we don't leave the iPhone
    # holding a stale simulation or a half-open RSD tunnel.
    try:
        await manager.disconnect_all()
    except Exception:
        logging.getLogger("lociighostd").exception("disconnect_all on shutdown failed")

    try:
        await osrm.close()
    except Exception:
        logging.getLogger("lociighostd").exception("osrm.close on shutdown failed")

    for task in pending:
        task.cancel()
    for task in pending:
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass

    for task in done:
        if task is serve_task and task.exception() is not None:
            raise task.exception()  # type: ignore[misc]

    return 0


def _setup_logging(verbose: bool) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    log_file = logs_dir() / "lociighostd.log"
    handlers: list[logging.Handler] = [
        logging.StreamHandler(sys.stderr),
        logging.FileHandler(str(log_file), encoding="utf-8"),
    ]
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        handlers=handlers,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lociighostd")
    parser.add_argument("--socket", default=socket_path(), help="Unix socket path")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--version", action="version", version=__version__)
    args = parser.parse_args(argv)

    _setup_logging(args.verbose)
    log = logging.getLogger("lociighostd")
    log.info("lociighostd %s starting on %s", __version__, args.socket)

    try:
        return asyncio.run(_run(args.socket))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
