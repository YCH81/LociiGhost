"""Subscribe to usbmuxd device-attach / device-detach notifications.

The usbmuxd protocol exposes a `Listen` message: after sending it the
daemon stays connected and pushes `Attached` / `Detached` / `Paired`
plists every time something happens. We forward each event to the RPC
server as `event.device_changed`, which is the same shape the explicit
`device.connect` / `device.disconnect` handlers already broadcast — so
the GUI can drive a single refresh path regardless of trigger.

Event-driven, idle-friendly: this watcher blocks in `_receive()` waiting
on the kernel socket. No polling, no timers.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Awaitable, Callable

from pymobiledevice3.usbmux import PlistMuxConnection, create_mux

log = logging.getLogger(__name__)

# Restart loop backoff caps. usbmuxd is local and stable; if we lose it we
# probably won't get it back without a system event, so cap the wait short.
_BACKOFF_MIN = 0.5
_BACKOFF_MAX = 5.0


EventCallback = Callable[[str, str | None], Awaitable[None]]
"""Receives (status, udid). status is 'attached' | 'detached'.

For detached events udid is the SerialNumber if usbmuxd reported it, else
None when we only have the internal device id."""


class UsbmuxWatcher:
    def __init__(self, on_event: EventCallback) -> None:
        self._on_event = on_event
        self._task: asyncio.Task | None = None
        self._stop = asyncio.Event()

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run(), name="usbmux-watcher")

    async def stop(self) -> None:
        if self._task is None:
            return
        self._stop.set()
        self._task.cancel()
        try:
            await self._task
        except (asyncio.CancelledError, Exception):
            pass
        self._task = None

    async def _run(self) -> None:
        backoff = _BACKOFF_MIN
        while not self._stop.is_set():
            try:
                await self._listen_once()
                backoff = _BACKOFF_MIN  # reset after a clean session
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("usbmux watcher errored; reconnecting in %.1fs", backoff)
                try:
                    await asyncio.wait_for(self._stop.wait(), timeout=backoff)
                except asyncio.TimeoutError:
                    pass
                backoff = min(backoff * 2, _BACKOFF_MAX)

    async def _listen_once(self) -> None:
        mux = await create_mux()
        # The plist variant is the one that delivers `Attached`/`Detached`
        # notifications in a useful shape. Older binary clients only get
        # device IDs without the SerialNumber, which the GUI can't match.
        if not isinstance(mux, PlistMuxConnection):
            log.warning("usbmux returned non-plist connection; subscription disabled")
            await mux.close()
            return

        try:
            await mux.listen()
            # Map device-id -> serial so a Detached event (which only carries
            # the internal id) can be reported back to the GUI as a UDID.
            id_to_udid: dict[int, str] = {}
            log.info("usbmux subscription active")
            while not self._stop.is_set():
                response = await mux._receive()  # type: ignore[attr-defined]
                msg = response if isinstance(response, dict) else None
                if msg is None:
                    continue
                msg_type = msg.get("MessageType")
                if msg_type == "Attached":
                    udid = msg.get("Properties", {}).get("SerialNumber")
                    devid = msg.get("DeviceID")
                    if udid is not None and devid is not None:
                        id_to_udid[devid] = udid
                    if udid:
                        await self._on_event("attached", udid)
                elif msg_type == "Detached":
                    devid = msg.get("DeviceID")
                    udid = id_to_udid.pop(devid, None) if devid is not None else None
                    await self._on_event("detached", udid)
                elif msg_type == "Paired":
                    # Doesn't change the connected set; ignore.
                    continue
                else:
                    log.debug("ignoring usbmux event: %s", msg_type)
        finally:
            try:
                await mux.close()
            except Exception:
                pass
