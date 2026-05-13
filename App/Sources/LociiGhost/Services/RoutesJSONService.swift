import Foundation
import LociiGhostCore

/// JSON import / export for saved Routes — analogous to
/// `BookmarksJSONService`. A route is an ordered list of (lat, lng)
/// points plus a name + optional category.
///
/// Shape (round-trip safe):
///
///     {
///       "version": "1.0",
///       "exported_at": "2026-05-12T...",
///       "routes": [
///         {
///           "name": "...",
///           "category": "...",        // optional, may be ""
///           "icon": "...",            // SF Symbol name, optional
///           "points": [
///             {"lat": 24.135, "lng": 120.692},
///             ...
///           ]
///         }
///       ]
///     }
enum RoutesJSONService {

    // ── Import ──────────────────────────────────────────────────

    private struct ImportPayload: Decodable {
        struct Route: Decodable {
            struct Point: Decodable { let lat: Double; let lng: Double }
            let name: String?
            let category: String?
            let icon: String?
            // `points` is LociiGhost's native key. `waypoints` is the
            // key LocWarp (upstream) uses — accepting both lets users
            // import a `locwarp-routes.json` export directly without
            // a schema conversion step.
            let points: [Point]?
            let waypoints: [Point]?

            var coords: [Point] { points ?? waypoints ?? [] }
        }
        let routes: [Route]?
    }

    struct Imported: Sendable {
        let name: String
        let category: String
        let iconSymbol: String?
        let points: [Coordinate]
    }

    /// Decode a JSON file into a flat list of route records. Throws on
    /// malformed JSON; returns an empty array if the file parses but
    /// has no routes. Drops individual routes that fail validation
    /// (zero points, out-of-range coords) rather than failing the
    /// whole import — better to land 9/10 than 0/10.
    static func parse(url: URL) throws -> [Imported] {
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(ImportPayload.self, from: data)
        var out: [Imported] = []
        out.reserveCapacity(payload.routes?.count ?? 0)
        for r in payload.routes ?? [] {
            let coords: [Coordinate] = r.coords.compactMap { p in
                guard (-90.0...90.0).contains(p.lat),
                      (-180.0...180.0).contains(p.lng)
                else { return nil }
                return Coordinate(lat: p.lat, lng: p.lng)
            }
            guard !coords.isEmpty else { continue }
            let name = (r.name?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "Imported route"
            out.append(Imported(
                name: name,
                category: r.category ?? "",
                iconSymbol: r.icon,
                points: coords,
            ))
        }
        return out
    }

    // ── Export ──────────────────────────────────────────────────

    private struct ExportPayload: Encodable {
        struct Route: Encodable {
            let name: String
            let category: String
            let icon: String
            let points: [Point]
        }
        struct Point: Encodable { let lat: Double; let lng: Double }
        let version: String
        let exported_at: String
        let routes: [Route]
    }

    /// Serialise the supplied LociiGhost Route records into JSON. The
    /// caller does the SwiftData fetch so this stays a pure function.
    static func encodeExport(routes: [LociiGhost.Route]) throws -> Data {
        let out = routes
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { r in
                ExportPayload.Route(
                    name: r.name,
                    category: r.category,
                    icon: r.iconSymbol,
                    points: r.points.map { ExportPayload.Point(lat: $0.lat, lng: $0.lng) },
                )
            }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let payload = ExportPayload(
            version: "1.0",
            exported_at: fmt.string(from: .now),
            routes: out,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }
}
