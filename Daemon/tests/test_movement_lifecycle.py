"""Runner lifecycle: only ever one thing driving a device.

Regression cover for the v1.15.2 audit findings L1 and L4 — the phone
endpoints stopped only some movers, and the stop/attach pair had await
points between them, so two movers could end up ticking into the same
location service at once.
"""
from __future__ import annotations

import asyncio

import pytest

from lociighostd.device_manager import DeviceManager

from ._fakes import FakeLocation, FakeRunner, make_session

pytestmark = pytest.mark.asyncio


async def test_attach_runner_stops_every_other_mover():
    mgr = DeviceManager()
    sess = make_session(mgr)
    walker, joystick = FakeRunner("walker"), FakeRunner("joystick")
    sess.walker, sess.joystick = walker, joystick
    walker.start(); joystick.start()

    nav = FakeRunner("nav")
    stopped = await mgr.attach_runner("UDID-1", "navigator", nav)

    assert stopped is True
    assert walker.stopped and joystick.stopped
    assert sess.walker is None and sess.joystick is None
    assert sess.navigator is nav and nav.started


async def test_concurrent_attaches_leave_exactly_one_mover():
    """The L4 race: two RPCs arriving together each saw an empty
    session, each stopped nothing, and each attached."""
    mgr = DeviceManager()
    sess = make_session(mgr)

    nav, joy = FakeRunner("nav"), FakeRunner("joy")
    await asyncio.gather(
        mgr.attach_runner("UDID-1", "navigator", nav),
        mgr.attach_runner("UDID-1", "joystick", joy),
    )

    live = [a for a in DeviceManager.MOVER_ATTRS if getattr(sess, a) is not None]
    assert len(live) == 1, f"expected one mover, found {live}"
    # Whichever lost the race must have been stopped, not orphaned.
    for runner in (nav, joy):
        if getattr(sess, "navigator") is not runner and getattr(sess, "joystick") is not runner:
            assert runner.stopped or not runner.started


async def test_stop_all_movement_reports_whether_anything_ran():
    mgr = DeviceManager()
    sess = make_session(mgr)
    assert await mgr.stop_all_movement("UDID-1") is False

    nav = FakeRunner("nav"); nav.start()
    sess.navigator = nav
    assert await mgr.stop_all_movement("UDID-1") is True
    assert sess.navigator is None and nav.stopped


async def test_stop_all_movement_on_unknown_device_is_quiet():
    mgr = DeviceManager()
    assert await mgr.stop_all_movement("nope") is False


async def test_slow_stop_is_bounded_and_cancelled():
    """Navigator.stop() awaits its own loop, which can be parked inside
    a location set(). An unbounded wait here is what turned a WiFi blip
    into a ten-second Stop spinner."""
    mgr = DeviceManager()
    sess = make_session(mgr)
    slow = FakeRunner("slow", stop_delay=30.0)
    slow.start()
    sess.navigator = slow

    started = asyncio.get_running_loop().time()
    await asyncio.wait_for(mgr.stop_all_movement("UDID-1"), timeout=10.0)
    elapsed = asyncio.get_running_loop().time() - started

    assert elapsed < DeviceManager.MOVER_STOP_TIMEOUT_S + 1.0
    assert sess.navigator is None
    assert slow._task is not None and slow._task.cancelled() or slow._task.done()


async def test_attach_runner_rejects_unknown_kind():
    mgr = DeviceManager()
    make_session(mgr)
    with pytest.raises(ValueError):
        await mgr.attach_runner("UDID-1", "teleporter", FakeRunner())


async def test_reconnect_tasks_are_referenced_and_cancellable():
    """asyncio keeps only a weak reference to a running task, so a
    fire-and-forget create_task can be collected mid-execution — and
    the auto-reconnect spends almost all of its life asleep in a
    2/5/10 s backoff, which is exactly when that would happen."""
    import gc

    mgr = DeviceManager()
    started = asyncio.Event()

    async def slow_reconnect(udid, hint, on_reconnect=None):
        started.set()
        await asyncio.sleep(30)

    mgr._attempt_reconnect = slow_reconnect        # noqa: SLF001
    sess = make_session(mgr)
    sess.reconnect_hint = {"kind": "connect", "prefer_wifi": False}
    loc = FakeLocation()
    loc.consecutive_keepalive_failures = loc.KEEPALIVE_DEAD_AFTER
    sess.location = loc

    lost = []
    await mgr._health_check_once(                  # noqa: SLF001
        lambda udid, reason: lost.append((udid, reason)),
        probe_timeout=0.1,
    )
    await asyncio.wait_for(started.wait(), timeout=2.0)
    assert mgr._reconnect_tasks, "no strong reference kept"   # noqa: SLF001

    gc.collect()                                    # would reap a weak-only task
    assert all(not t.done() for t in mgr._reconnect_tasks)    # noqa: SLF001

    # Shutdown must not leave one asleep, ready to rebuild a session
    # that is being torn down.
    await mgr.disconnect_all()
    assert not mgr._reconnect_tasks                 # noqa: SLF001
