"""Unit tests for DeviceManager. Mocks out pymobiledevice3 entirely."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from locwarpd.device_manager import DeviceManager
from locwarpd.errors import DEVICE_NOT_CONNECTED, DEVICE_NOT_FOUND, UNSUPPORTED_IOS
from locwarpd.models import parse_ios_version
from locwarpd.rpc import RpcError

pytestmark = pytest.mark.asyncio(loop_scope="function")


def _raw_device(serial: str, conn: str = "USB") -> MagicMock:
    m = MagicMock()
    m.serial = serial
    m.connection_type = conn
    return m


def _lockdown(name: str = "Test iPhone", version: str = "17.4.1") -> MagicMock:
    m = MagicMock()
    m.all_values = {"DeviceName": name, "ProductVersion": version}
    return m


# ----------------------------------------------------------------------
# parse_ios_version
# ----------------------------------------------------------------------

def test_parse_ios_version_normal():
    assert parse_ios_version("17.4.1") == (17, 4, 1)
    assert parse_ios_version("16.0") == (16, 0)


def test_parse_ios_version_garbage():
    assert parse_ios_version("not-a-version") == (0, 0)
    assert parse_ios_version("") == (0, 0)


# ----------------------------------------------------------------------
# list_devices
# ----------------------------------------------------------------------

@pytest.mark.asyncio
async def test_list_devices_empty():
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=[])):
        dm = DeviceManager()
        devices = await dm.list_devices()
        assert devices == []


@pytest.mark.asyncio
async def test_list_devices_one_iphone():
    raw = [_raw_device("ABC", "USB")]
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=raw)), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=_lockdown("My iPhone", "17.4.1"))):
        dm = DeviceManager()
        devices = await dm.list_devices()

        assert len(devices) == 1
        d = devices[0]
        assert d.udid == "ABC"
        assert d.name == "My iPhone"
        assert d.ios_version == "17.4.1"
        assert d.transport == "usb"
        assert d.connected is False


@pytest.mark.asyncio
async def test_list_devices_dedupes_usb_over_network():
    """If the same UDID shows up as both Network and USB, prefer USB but
    surface BOTH transports so the GUI can offer a 'Connect via WiFi'
    action even when USB is currently plugged in."""
    raw = [
        _raw_device("ABC", "Network"),
        _raw_device("ABC", "USB"),
    ]
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=raw)), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=_lockdown())):
        dm = DeviceManager()
        devices = await dm.list_devices()
        assert len(devices) == 1
        # The active transport is USB (preferred when both are present).
        assert devices[0].transport == "usb"
        # And both transports are surfaced so the UI can render badges.
        assert set(devices[0].transports) == {"usb", "network"}


@pytest.mark.asyncio
async def test_list_devices_wifi_only_marks_only_network():
    raw = [_raw_device("ABC", "Network")]
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=raw)), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=_lockdown())):
        dm = DeviceManager()
        devices = await dm.list_devices()
        assert len(devices) == 1
        assert devices[0].transport == "network"
        assert set(devices[0].transports) == {"network"}


@pytest.mark.asyncio
async def test_connect_prefer_wifi_picks_network_when_available():
    raw = [_raw_device("X", "USB"), _raw_device("X", "Network")]

    captured: list[str | None] = []

    async def capturing_lockdown(*, serial: str, connection_type: str | None = None, **_kw):
        captured.append(connection_type)
        return _lockdown(version="17.4")

    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=raw)), \
         patch("locwarpd.device_manager.create_using_usbmux", side_effect=capturing_lockdown), \
         patch("locwarpd.device_manager.CoreDeviceTunnelProxy"):
        dm = DeviceManager()
        # Force WiFi: Network transport must be requested.
        try:
            await dm.connect("X", prefer_wifi=True)
        except Exception:
            # Connection setup proper isn't what this test is verifying;
            # we only care that the lockdown was opened with the right
            # connection_type before tunnel work began.
            pass
        assert "Network" in captured


@pytest.mark.asyncio
async def test_list_devices_skips_failed_lockdown():
    raw = [_raw_device("good"), _raw_device("bad")]

    async def fake_lockdown(serial: str):
        if serial == "bad":
            raise RuntimeError("permission denied")
        return _lockdown()

    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=raw)), \
         patch("locwarpd.device_manager.create_using_usbmux", side_effect=fake_lockdown):
        dm = DeviceManager()
        devices = await dm.list_devices()
        assert [d.udid for d in devices] == ["good"]


# ----------------------------------------------------------------------
# connect
# ----------------------------------------------------------------------

@pytest.mark.asyncio
async def test_connect_unsupported_ios_raises():
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=[_raw_device("X")])), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=_lockdown(version="15.0"))):
        dm = DeviceManager()
        with pytest.raises(RpcError) as ei:
            await dm.connect("X")
        assert ei.value.code == UNSUPPORTED_IOS


@pytest.mark.asyncio
async def test_connect_legacy_ios16(monkeypatch):
    """iOS 16.x should NOT try to set up an RSD tunnel."""
    raw = [_raw_device("X")]
    proxy_mock = MagicMock()
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=raw)), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=_lockdown(version="16.5"))), \
         patch("locwarpd.device_manager.CoreDeviceTunnelProxy", proxy_mock):
        dm = DeviceManager()
        info = await dm.connect("X")
        assert info.connected
        assert info.ios_version == "16.5"
        # Crucially, no tunnel was attempted on 16.x.
        proxy_mock.create.assert_not_called()


@pytest.mark.asyncio
async def test_connect_idempotent():
    raw = [_raw_device("X")]
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=raw)), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=_lockdown(version="16.5"))):
        dm = DeviceManager()
        first = await dm.connect("X")
        second = await dm.connect("X")
        assert first.udid == second.udid == "X"
        assert second.connected


@pytest.mark.asyncio
async def test_connect_lockdown_failure_maps_to_device_not_found():
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=[])), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(side_effect=RuntimeError("nope"))):
        dm = DeviceManager()
        with pytest.raises(RpcError) as ei:
            await dm.connect("UNKNOWN")
        assert ei.value.code == DEVICE_NOT_FOUND


# ----------------------------------------------------------------------
# location_for
# ----------------------------------------------------------------------

@pytest.mark.asyncio
async def test_location_for_disconnected_raises():
    dm = DeviceManager()
    with pytest.raises(RpcError) as ei:
        await dm.location_for("nope")
    assert ei.value.code == DEVICE_NOT_CONNECTED


# ----------------------------------------------------------------------
# disconnect
# ----------------------------------------------------------------------

@pytest.mark.asyncio
async def test_disconnect_unknown_returns_false():
    dm = DeviceManager()
    assert await dm.disconnect("nope") is False


@pytest.mark.asyncio
async def test_disconnect_legacy_session():
    raw = [_raw_device("X")]
    with patch("locwarpd.device_manager.list_devices", AsyncMock(return_value=raw)), \
         patch("locwarpd.device_manager.create_using_usbmux", AsyncMock(return_value=_lockdown(version="16.5"))):
        dm = DeviceManager()
        await dm.connect("X")
        assert await dm.disconnect("X") is True
        # Second disconnect is a no-op.
        assert await dm.disconnect("X") is False
