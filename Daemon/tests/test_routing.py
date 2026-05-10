"""Test OSRM response parsing + cache. Network is mocked via httpx.MockTransport."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import httpx
import pytest

from lociighostd import paths
from lociighostd.routing import OsrmClient, Route, RoutingError

pytestmark = pytest.mark.asyncio(loop_scope="function")


# Sample OSRM response (geometry simplified, real shape).
_SAMPLE_OSRM = {
    "code": "Ok",
    "routes": [
        {
            "distance": 1234.5,
            "duration": 87.6,
            "geometry": {
                "type": "LineString",
                "coordinates": [
                    [121.5654, 25.0330],
                    [121.5660, 25.0335],
                    [121.5670, 25.0340],
                ],
            },
        }
    ],
}


def _mock_client(response_payload, base_url="https://example.test/route/v1") -> OsrmClient:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=response_payload)

    transport = httpx.MockTransport(handler)
    client = OsrmClient(base_url=base_url)
    # Replace the real http client with a mocked one so no network is hit.
    client._http = httpx.AsyncClient(transport=transport, timeout=5.0)
    return client


@pytest.fixture(autouse=True)
def isolated_cache(monkeypatch, tmp_path):
    """Redirect routes.sqlite3 into a fresh temp dir per test.

    routing.py uses `from .paths import cache_dir`, so the binding lives on
    the `routing` module — patching the original `paths` attribute would be
    a no-op against an already-imported symbol.
    """
    monkeypatch.setattr("lociighostd.routing.cache_dir", lambda: tmp_path)


@pytest.mark.asyncio
async def test_route_parses_geojson_to_lat_lng():
    client = _mock_client(_SAMPLE_OSRM)
    try:
        route = await client.route(25.0, 121.0, 25.1, 121.1, "driving")
    finally:
        await client.close()
    # Coordinates should be in lat,lng order (OSRM gives lng,lat).
    assert route.coordinates[0] == (25.0330, 121.5654)
    assert route.coordinates[-1] == (25.0340, 121.5670)
    assert route.distance_m == 1234.5
    assert route.duration_s == 87.6
    assert route.profile == "driving"


@pytest.mark.asyncio
async def test_route_unknown_profile_raises():
    client = _mock_client(_SAMPLE_OSRM)
    try:
        with pytest.raises(RoutingError):
            await client.route(0, 0, 1, 1, "teleport")
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_route_osrm_error_payload():
    client = _mock_client({"code": "NoRoute", "message": "no path"})
    try:
        with pytest.raises(RoutingError):
            await client.route(0, 0, 1, 1, "driving")
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_route_cache_hit_avoids_second_request():
    call_count = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        call_count["n"] += 1
        return httpx.Response(200, json=_SAMPLE_OSRM)

    transport = httpx.MockTransport(handler)
    client = OsrmClient(base_url="https://example.test/route/v1")
    client._http = httpx.AsyncClient(transport=transport, timeout=5.0)
    try:
        await client.route(25.0, 121.0, 25.1, 121.1, "driving")
        await client.route(25.0, 121.0, 25.1, 121.1, "driving")
        assert call_count["n"] == 1
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_route_to_json_round_trips():
    client = _mock_client(_SAMPLE_OSRM)
    try:
        route = await client.route(25.0, 121.0, 25.1, 121.1, "driving")
    finally:
        await client.close()
    payload = route.to_json()
    assert payload["distance_m"] == 1234.5
    assert payload["coordinates"][0] == {"lat": 25.0330, "lng": 121.5654}
