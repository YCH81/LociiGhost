import Foundation
import MapKit
import CoreLocation

/// Mac-side route resolver that uses Apple's MKDirections to plan
/// routes between consecutive waypoints, then concatenates the
/// returned polylines into one flat coordinate sequence.
///
/// Why on the Mac (not in the daemon): MKDirections is an
/// AppleSDK-only API; the Python daemon can't reach it. So we resolve
/// the route here and ship the resulting polyline to the daemon as a
/// pre-resolved coordinate list — the daemon's Navigator then plays
/// it back tick-by-tick exactly the same way it plays an
/// OSRM-resolved route.
///
/// Multi-waypoint handling: MKDirections only routes between ONE
/// origin and ONE destination per request. For N waypoints we issue
/// N-1 sequential `calculate()` calls between consecutive pairs and
/// stitch the polylines (dropping the duplicate junction point
/// between adjacent legs so the playback doesn't "stutter" at every
/// stop).
///
/// Cycling profile: Apple's transport types are
/// `automobile` / `walking` / `transit` — there is no `bicycle`.
/// For our `cycling` profile we ask MKDirections for automobile
/// geometry; SpeedPicker on playback supplies the actual bike pace,
/// which mirrors the OSRM-NoRoute → car-retry fallback shipped in
/// v1.9.4 and is acceptable for a GPS-spoof tool where the visible
/// route only needs to look road-shaped.
enum MapKitRouter {

    /// Result of resolving a waypoint list to a flat polyline.
    /// Mirrors the shape the daemon's `Route` returns, so the
    /// downstream code path (Navigator, ETA, distance display) sees
    /// the same data regardless of which engine produced it.
    struct ResolvedRoute: Sendable {
        let coordinates: [Coordinate]
        let distanceMeters: Double
        let durationSeconds: Double
        /// The profile the *user* asked for (driving / walking /
        /// cycling). Independent of what MKDirections actually used —
        /// e.g. cycling will have been resolved as automobile under
        /// the hood. Daemon stores this for UI display; playback
        /// speed comes from SpeedPicker, not from this field.
        let profile: String
    }

    enum RouterError: Error, LocalizedError {
        case insufficientWaypoints
        case legFailed(legIndex: Int, underlying: Error)
        case noRouteReturned(legIndex: Int)

        var errorDescription: String? {
            switch self {
            case .insufficientWaypoints:
                return "Need at least 2 waypoints to plan a route."
            case .legFailed(let i, let err):
                return "MapKit failed to route leg \(i + 1): \(err.localizedDescription)"
            case .noRouteReturned(let i):
                return "MapKit returned no route for leg \(i + 1)."
            }
        }
    }

    /// Resolve `waypoints` into a single polyline using MKDirections.
    ///
    /// - Parameters:
    ///   - waypoints: ordered list of points the user wants to visit.
    ///     Must have at least 2.
    ///   - profile: "driving" / "walking" / "cycling". Cycling falls
    ///     back to driving geometry (see type docs).
    /// - Returns: a `ResolvedRoute` ready to send to the daemon as a
    ///   pre-resolved polyline.
    static func resolve(
        waypoints: [Coordinate],
        profile: String,
    ) async throws -> ResolvedRoute {
        guard waypoints.count >= 2 else {
            throw RouterError.insufficientWaypoints
        }

        let transport = transportType(for: profile)
        var stitched: [Coordinate] = []
        var totalDistance: Double = 0
        var totalDuration: Double = 0

        for legIdx in 0..<(waypoints.count - 1) {
            let a = waypoints[legIdx]
            let b = waypoints[legIdx + 1]
            let route: MKRoute
            do {
                route = try await legRoute(from: a, to: b, transport: transport)
            } catch {
                throw RouterError.legFailed(legIndex: legIdx, underlying: error)
            }

            let legCoords = polylineCoordinates(route.polyline)
            // Drop the duplicate junction point: the last point of
            // the previous leg is the same place as the first point
            // of this leg, since legs share their boundary waypoint.
            // Without this drop the playback "double-ticks" at every
            // intermediate stop.
            if stitched.isEmpty {
                stitched.append(contentsOf: legCoords)
            } else if !legCoords.isEmpty {
                stitched.append(contentsOf: legCoords.dropFirst())
            }
            totalDistance += route.distance
            totalDuration += route.expectedTravelTime
        }

        return ResolvedRoute(
            coordinates: stitched,
            distanceMeters: totalDistance,
            durationSeconds: totalDuration,
            profile: profile,
        )
    }

    // MARK: - Helpers

    /// One MKDirections call between two endpoints. Wrapped in
    /// async/throws because MKDirections.calculate uses an old
    /// closure-style completion handler.
    private static func legRoute(
        from a: Coordinate,
        to b: Coordinate,
        transport: MKDirectionsTransportType,
    ) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.transportType = transport
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lng),
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lng),
        ))
        // We only need one route, the first/best one. Setting this
        // saves MapKit a little work and keeps the response small.
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        guard let first = response.routes.first else {
            // Treat "no route" the same as any other failure; caller
            // wraps it in legFailed for the user-facing toast.
            throw NSError(
                domain: "MapKitRouter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No route returned"],
            )
        }
        return first
    }

    /// Pull each lat/lng point out of an MKPolyline. MKPolyline stores
    /// coordinates as a contiguous C buffer (`getCoordinates`),
    /// indexable by point count — no Swift idiomatic accessor.
    private static func polylineCoordinates(_ polyline: MKPolyline) -> [Coordinate] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var raw = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: count,
        )
        polyline.getCoordinates(&raw, range: NSRange(location: 0, length: count))
        return raw.map { Coordinate(lat: $0.latitude, lng: $0.longitude) }
    }

    /// Map our friendly profile names to MKDirectionsTransportType.
    /// `cycling` falls through to automobile — see type-level docs.
    private static func transportType(for profile: String) -> MKDirectionsTransportType {
        switch profile {
        case "walking": return .walking
        case "cycling": return .automobile   // no native bike; SpeedPicker compensates
        case "driving": return .automobile
        default:        return .automobile
        }
    }
}
