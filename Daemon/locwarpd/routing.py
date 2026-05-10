"""OSRM routing client with a tiny SQLite cache.

We use the public OSRM demo server (router.project-osrm.org) by default.
It's rate-limited and not for production-grade traffic, but it's free,
needs no API key, and is plenty for one user driving a teleport tool.

Routes are cached by (from, to, profile) so re-running the same route
doesn't re-hit the network. Cache lives in `~/Library/Caches/LocWarp.Mac/`
and entries expire after 30 days.
"""

from __future__ import annotations

import json
import logging
import sqlite3
import time
from dataclasses import dataclass
from typing import Any

import httpx

from .paths import cache_dir

log = logging.getLogger(__name__)

# Map our profile names to OSRM's. We expose the friendlier names so
# the GUI can present "Walking" / "Driving" / "Cycling" without leaking
# OSRM-specific terminology.
PROFILES = {
    "walking": "foot",
    "cycling": "bike",
    "driving": "car",
}

CACHE_TTL_SECONDS = 30 * 24 * 60 * 60     # 30 days
DEFAULT_BASE_URL = "https://router.project-osrm.org/route/v1"


class RoutingError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class Route:
    """One computed route from A to B."""
    coordinates: list[tuple[float, float]]    # list of (lat, lng), in path order
    distance_m: float
    duration_s: float
    profile: str

    def to_json(self) -> dict[str, Any]:
        return {
            "coordinates": [{"lat": c[0], "lng": c[1]} for c in self.coordinates],
            "distance_m": self.distance_m,
            "duration_s": self.duration_s,
            "profile": self.profile,
        }


class OsrmClient:
    """Async OSRM HTTP client with a SQLite cache.

    Single instance per daemon. Closed on shutdown so the underlying
    httpx client can release its connection pool.
    """

    def __init__(self, base_url: str = DEFAULT_BASE_URL) -> None:
        self.base_url = base_url.rstrip("/")
        self._http = httpx.AsyncClient(timeout=15.0)
        self._db = _open_cache()

    async def close(self) -> None:
        try:
            await self._http.aclose()
        except Exception:
            pass
        try:
            self._db.close()
        except Exception:
            pass

    async def route(
        self,
        from_lat: float,
        from_lng: float,
        to_lat: float,
        to_lng: float,
        profile: str = "driving",
    ) -> Route:
        """Single-leg convenience wrapper around `route_through`."""
        return await self.route_through(
            [(from_lat, from_lng), (to_lat, to_lng)],
            profile=profile,
        )

    async def route_through(
        self,
        waypoints: list[tuple[float, float]],
        profile: str = "driving",
    ) -> Route:
        """Compute a single route that visits each (lat, lng) in `waypoints`
        in order. Two waypoints = simple A→B; more = multi-stop. OSRM
        natively supports the multi-waypoint URL form so this is one
        request regardless of stop count."""
        if profile not in PROFILES:
            raise RoutingError(
                f"Unknown profile {profile!r}; expected one of {sorted(PROFILES)}"
            )
        if len(waypoints) < 2:
            raise RoutingError("route needs at least 2 waypoints")

        cache_key = self._cache_key(waypoints, profile)
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached

        osrm_profile = PROFILES[profile]
        coords_part = ";".join(f"{lng},{lat}" for lat, lng in waypoints)
        url = f"{self.base_url}/{osrm_profile}/{coords_part}"
        params = {"overview": "full", "geometries": "geojson"}

        try:
            resp = await self._http.get(url, params=params)
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise RoutingError(f"OSRM request failed: {exc}") from exc

        try:
            data = resp.json()
        except ValueError as exc:
            raise RoutingError("OSRM returned non-JSON response") from exc

        if data.get("code") != "Ok":
            raise RoutingError(
                f"OSRM error: {data.get('code')} {data.get('message', '')}"
            )

        routes = data.get("routes") or []
        if not routes:
            raise RoutingError("OSRM returned no routes")

        first = routes[0]
        # OSRM geojson is [lng, lat] per spec; normalise to (lat, lng).
        raw_coords = first.get("geometry", {}).get("coordinates") or []
        coords: list[tuple[float, float]] = [(c[1], c[0]) for c in raw_coords if len(c) >= 2]
        if not coords:
            raise RoutingError("OSRM route had no geometry")

        route = Route(
            coordinates=coords,
            distance_m=float(first.get("distance", 0.0)),
            duration_s=float(first.get("duration", 0.0)),
            profile=profile,
        )
        self._cache_put(cache_key, route)
        return route

    # ------------------------------------------------------------------
    # Cache helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _cache_key(waypoints: list[tuple[float, float]], profile: str) -> str:
        # 5 decimal places ≈ 1.1 m. More than enough for cache identity.
        joined = "|".join(f"{lat:.5f},{lng:.5f}" for lat, lng in waypoints)
        return f"{profile}|{joined}"

    def _cache_get(self, key: str) -> Route | None:
        try:
            row = self._db.execute(
                "SELECT payload, fetched_at FROM routes WHERE key = ?",
                (key,),
            ).fetchone()
        except sqlite3.DatabaseError:
            log.warning("route cache read failed", exc_info=True)
            return None
        if row is None:
            return None
        payload, fetched_at = row
        if time.time() - fetched_at > CACHE_TTL_SECONDS:
            return None
        try:
            obj = json.loads(payload)
            coords = [(c["lat"], c["lng"]) for c in obj["coordinates"]]
            return Route(
                coordinates=coords,
                distance_m=obj["distance_m"],
                duration_s=obj["duration_s"],
                profile=obj["profile"],
            )
        except (json.JSONDecodeError, KeyError, TypeError):
            return None

    def _cache_put(self, key: str, route: Route) -> None:
        try:
            self._db.execute(
                "INSERT OR REPLACE INTO routes (key, payload, fetched_at) VALUES (?, ?, ?)",
                (key, json.dumps(route.to_json()), time.time()),
            )
            self._db.commit()
        except sqlite3.DatabaseError:
            log.warning("route cache write failed", exc_info=True)


def _open_cache() -> sqlite3.Connection:
    path = cache_dir() / "routes.sqlite3"
    db = sqlite3.connect(str(path), isolation_level=None, check_same_thread=False)
    db.execute("PRAGMA journal_mode = WAL")
    db.execute(
        """
        CREATE TABLE IF NOT EXISTS routes (
            key        TEXT PRIMARY KEY,
            payload    TEXT NOT NULL,
            fetched_at REAL NOT NULL
        )
        """
    )
    return db
