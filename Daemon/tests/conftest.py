"""Test-suite-wide fixtures.

Most tests don't have a real iPhone on the network and certainly don't
want to spend 3 seconds per `list_devices` call doing a Bonjour browse.
This conftest auto-patches the WiFiDiscovery so it always returns an
empty mapping; individual tests can opt back in by patching it again
locally.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest


@pytest.fixture(autouse=True)
def stub_wifi_discovery(monkeypatch):
    """Replace `WiFiDiscovery` with a stub for every test that touches
    the device manager. Real Bonjour browse takes seconds and depends
    on the host network state — neither is appropriate in unit tests.
    """
    # Build the stub once and let the same instance be used for every
    # `WiFiDiscovery()` call inside the test.
    stub = MagicMock(name="WiFiDiscovery")
    stub.discover = AsyncMock(return_value={})
    stub.targets_for = MagicMock(return_value=[])
    stub.open_tunnel_service = AsyncMock()
    stub.paired_udids = []

    monkeypatch.setattr(
        "locwarpd.device_manager.WiFiDiscovery",
        lambda *args, **kwargs: stub,
    )
    yield stub
