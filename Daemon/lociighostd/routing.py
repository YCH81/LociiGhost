"""OSRM routing client with a tiny SQLite cache.

We use the public OSRM demo server (router.project-osrm.org) by default.
It's rate-limited and not for production-grade traffic, but it's free,
needs no API key, and is plenty for one user driving a teleport tool.

Routes are cached by (from, to, profile) so re-running the same route
doesn't re-hit the network. Cache lives in `~/Library/Caches/LociiGhost/`
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
# OSRM-specific terminology. The public demo at router.project-osrm.org
# DOES serve all three — but bike/foot have a noticeably sparser graph
# (no path across highway-only bridges, restricted tunnels, etc.) and
# will return a 400 `NoRoute` when a waypoint pair has no bike/foot
# connection. Callers should catch `NoRouteError` and retry with
# "driving" before surfacing the failure to the user.
PROFILES = {
    "walking": "foot",
    "cycling": "bike",
    "driving": "car",
}

CACHE_TTL_SECONDS = 30 * 24 * 60 * 60     # 30 days
DEFAULT_BASE_URL = "https://router.project-osrm.org/route/v1"


class RoutingError(RuntimeError):
    pass


class NoRouteError(RoutingError):
    """OSRM returned `code: NoRoute` — the chosen profile can't connect
    every waypoint (typically bike/foot across a stretch that only has
    a car-accessible road). Callers may want to retry with a more
    permissive profile before failing the user-facing request."""
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
        except httpx.HTTPStatusError as exc:
            # OSRM returns 400 with a JSON body like {"code":"NoRoute"}
            # when the chosen profile can't connect every waypoint.
            # Surface that as its own exception so handlers.py can
            # retry with car before giving up.
            if exc.response.status_code == 400:
                try:
                    body = exc.response.json()
                    if body.get("code") == "NoRoute":
                        raise NoRouteError(
                            body.get("message", "no route found")
                        ) from exc
                except ValueError:
                    pass
            raise RoutingError(f"OSRM request failed: {exc}") from exc
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


class GoogleDirectionsClient:
    """Minimal async Google Directions API client.

    Returns the same `Route` shape as `OsrmClient` so callers can
    treat both engines uniformly. Constructed per-request because the
    API key is user-provided and may change; the underlying httpx
    AsyncClient is opened/closed in `route_through` rather than held
    long-term to avoid leaking sockets when the user toggles back to
    OSRM mid-session.

    Profile mapping:
      driving  → mode=driving
      cycling  → mode=bicycling
      walking  → mode=walking

    See https://developers.google.com/maps/documentation/directions
    for the endpoint and quota / billing rules. The user owns the
    key and gets the bill.
    """

    BASE_URL = "https://maps.googleapis.com/maps/api/directions/json"
    PROFILE_MAP = {
        "driving": "driving",
        "cycling": "bicycling",
        "walking": "walking",
    }

    def __init__(self, api_key: str) -> None:
        self.api_key = api_key

    async def route_through(
        self,
        waypoints: list[tuple[float, float]],
        profile: str = "driving",
    ) -> Route:
        if profile not in self.PROFILE_MAP:
            raise RoutingError(
                f"Unknown profile {profile!r}; expected one of {sorted(self.PROFILE_MAP)}"
            )
        if len(waypoints) < 2:
            raise RoutingError("route needs at least 2 waypoints")
        if not self.api_key:
            raise RoutingError("Google Directions requires an API key")

        origin = f"{waypoints[0][0]},{waypoints[0][1]}"
        dest = f"{waypoints[-1][0]},{waypoints[-1][1]}"
        params: dict[str, Any] = {
            "origin": origin,
            "destination": dest,
            "mode": self.PROFILE_MAP[profile],
            "key": self.api_key,
        }
        # Optional intermediate stops. Google's `waypoints` query
        # parameter is a pipe-separated `lat,lng|lat,lng|...` list,
        # in the order we want them visited.
        intermediates = waypoints[1:-1]
        if intermediates:
            params["waypoints"] = "|".join(
                f"{lat},{lng}" for lat, lng in intermediates
            )

        async with httpx.AsyncClient(timeout=15.0) as http:
            try:
                resp = await http.get(self.BASE_URL, params=params)
                resp.raise_for_status()
            except httpx.HTTPError as exc:
                raise RoutingError(f"Google Directions request failed: {exc}") from exc

        try:
            data = resp.json()
        except ValueError as exc:
            raise RoutingError("Google returned non-JSON response") from exc

        status = data.get("status")
        if status != "OK":
            raise RoutingError(
                f"Google Directions error: {status} {data.get('error_message', '')}".strip()
            )

        routes = data.get("routes") or []
        if not routes:
            raise RoutingError("Google Directions returned no routes")

        first = routes[0]
        # Concatenate the per-step polylines so we get the full path
        # at navigation-friendly resolution (overview_polyline is too
        # coarse — long road segments end up as ~3 vertices).
        coords: list[tuple[float, float]] = []
        distance_m = 0.0
        duration_s = 0.0
        for leg in first.get("legs", []):
            distance_m += float(leg.get("distance", {}).get("value", 0.0))
            duration_s += float(leg.get("duration", {}).get("value", 0.0))
            for step in leg.get("steps", []):
                encoded = step.get("polyline", {}).get("points") or ""
                if not encoded:
                    continue
                step_coords = _decode_polyline(encoded)
                # Drop the first coord on every step past the first
                # — it's a duplicate of the previous step's last
                # coord and would create a stutter at the seam.
                if coords:
                    step_coords = step_coords[1:]
                coords.extend(step_coords)

        if not coords:
            # Fallback: overview_polyline. Better than failing.
            encoded = first.get("overview_polyline", {}).get("points") or ""
            if encoded:
                coords = _decode_polyline(encoded)

        if not coords:
            raise RoutingError("Google Directions route had no geometry")

        return Route(
            coordinates=coords,
            distance_m=distance_m,
            duration_s=duration_s,
            profile=profile,
        )


def _decode_polyline(encoded: str) -> list[tuple[float, float]]:
    """Decode a Google polyline-format string into a list of (lat, lng).

    Implements the standard `polyline encoding algorithm`_ inline so we
    don't pull in an extra runtime dep just for ~25 lines of code.

    .. _polyline encoding algorithm:
       https://developers.google.com/maps/documentation/utilities/polylinealgorithm
    """
    coords: list[tuple[float, float]] = []
    index = 0
    lat = 0
    lng = 0
    length = len(encoded)
    while index < length:
        # Latitude delta.
        shift = 0
        result = 0
        while index < length:
            b = ord(encoded[index]) - 63
            index += 1
            result |= (b & 0x1F) << shift
            shift += 5
            if b < 0x20:
                break
        dlat = ~(result >> 1) if (result & 1) else (result >> 1)
        lat += dlat
        # Longitude delta.
        shift = 0
        result = 0
        while index < length:
            b = ord(encoded[index]) - 63
            index += 1
            result |= (b & 0x1F) << shift
            shift += 5
            if b < 0x20:
                break
        dlng = ~(result >> 1) if (result & 1) else (result >> 1)
        lng += dlng
        coords.append((lat / 1e5, lng / 1e5))
    return coords


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
