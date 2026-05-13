import Foundation
import LociiGhostCore

/// Parser for the LocWarp-style bookmarks-export JSON.
///
/// Shape (subset we care about — extra fields are ignored):
///
///     {
///       "categories": [
///         { "id": "...", "name": "...", "color": "..." }
///       ],
///       "bookmarks": [
///         {
///           "id": "...", "name": "...",
///           "lat": 24.135, "lng": 120.692,
///           "category_id": "...",  // matches a category.id; optional
///           "country_code": "tw"   // ignored — we re-derive on display
///         }
///       ]
///     }
///
/// Returned tuples are ready to feed into `AppState.addBookmark`.
/// Category lookup is by `id`; an unknown id (or null id) falls back
/// to "" so the bookmark lands in the Uncategorized bin.
enum BookmarksJSONService {

    /// Plain decoded shape — kept private; the public surface is
    /// the `parse(...)` flat-list output.
    private struct Payload: Decodable {
        struct Category: Decodable {
            let id: String?
            let name: String?
        }
        struct Bookmark: Decodable {
            let name: String?
            let lat: Double?
            let lng: Double?
            let category_id: String?
        }
        let categories: [Category]?
        let bookmarks: [Bookmark]?
    }

    /// Public per-bookmark output. Pre-resolved category name so
    /// the caller doesn't need to know about the source's id-keyed
    /// indirection.
    struct Imported: Sendable {
        let name: String
        let lat: Double
        let lng: Double
        let category: String
    }

    /// Decode a JSON file into a flat list of bookmark records.
    /// Throws on malformed JSON; returns an empty array if the file
    /// parses but has no bookmarks (caller can show a "nothing to
    /// import" toast in that case rather than silently no-op'ing).
    static func parse(url: URL) throws -> [Imported] {
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        // Build a lookup table once instead of doing an O(N) scan
        // per bookmark — large exports (hundreds of bookmarks
        // across dozens of categories) would otherwise be O(N*M).
        var catLookup: [String: String] = [:]
        for c in payload.categories ?? [] {
            if let id = c.id, let name = c.name, !name.isEmpty {
                catLookup[id] = name
            }
        }
        var out: [Imported] = []
        out.reserveCapacity(payload.bookmarks?.count ?? 0)
        for b in payload.bookmarks ?? [] {
            guard let name = b.name, !name.isEmpty,
                  let lat = b.lat, let lng = b.lng,
                  (-90.0...90.0).contains(lat),
                  (-180.0...180.0).contains(lng)
            else { continue }
            let category: String
            if let cid = b.category_id, let resolved = catLookup[cid] {
                category = resolved
            } else {
                category = ""
            }
            out.append(Imported(
                name: name,
                lat: lat,
                lng: lng,
                category: category,
            ))
        }
        return out
    }

    // ── Export (v1.9) ───────────────────────────────────────────

    /// Encodable shape used for export. Mirrors the import payload so
    /// a round-trip is loss-free for the fields LociiGhost cares about.
    /// Categories get synthesized ids (`cat-<n>`) when emitting since
    /// our internal Bookmark model only stores the category NAME.
    private struct ExportPayload: Encodable {
        struct Category: Encodable {
            let id: String
            let name: String
        }
        struct Bookmark: Encodable {
            let name: String
            let lat: Double
            let lng: Double
            let category_id: String?
        }
        let version: String
        let exported_at: String
        let categories: [Category]
        let bookmarks: [Bookmark]
    }

    /// Serialise a list of in-app Bookmark records into LocWarp-style
    /// JSON. Group order is deterministic (sort by name) so two
    /// successive exports yield identical bytes — useful for diff'ing
    /// or syncing through a cloud drive.
    static func encodeExport(bookmarks: [LociiGhost.Bookmark]) throws -> Data {
        // Build a name→synthetic-id table for categories. Uncategorized
        // bookmarks (empty category string) emit with category_id: nil
        // so the importer sends them to the Uncategorized bin.
        let uniqueCategoryNames: [String] = {
            var seen = Set<String>()
            var ordered: [String] = []
            for bm in bookmarks {
                let trimmed = bm.category.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if seen.insert(trimmed).inserted {
                    ordered.append(trimmed)
                }
            }
            return ordered.sorted()
        }()

        var catIdByName: [String: String] = [:]
        var categories: [ExportPayload.Category] = []
        for (idx, name) in uniqueCategoryNames.enumerated() {
            let id = "cat-\(idx + 1)"
            catIdByName[name] = id
            categories.append(.init(id: id, name: name))
        }

        let bms: [ExportPayload.Bookmark] = bookmarks
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { bm in
                let trimmed = bm.category.trimmingCharacters(in: .whitespacesAndNewlines)
                let cid = trimmed.isEmpty ? nil : catIdByName[trimmed]
                return .init(name: bm.name, lat: bm.lat, lng: bm.lng, category_id: cid)
            }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload = ExportPayload(
            version: "1.0",
            exported_at: formatter.string(from: .now),
            categories: categories,
            bookmarks: bms,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    // ── Bulk-paste parser (v1.9) ────────────────────────────────

    /// Parse a multi-line text blob into bookmark candidates. Each
    /// non-empty line is one bookmark. Supported per-line shapes,
    /// tried in order:
    ///
    ///   1. `name, lat, lng[, category]` — 3 or 4 fields, lat/lng numeric
    ///   2. `lat, lng[, name][, category]` — 2-4 fields, lat/lng leading
    ///   3. `name` — name only (lat/lng = 0/0, user fixes later)
    ///
    /// Tab, comma, or semicolon all work as separators. Empty lines
    /// and `#`-prefixed comment lines are skipped. Invalid coords
    /// (out of range) cause the line to be dropped.
    static func parseBulkPaste(_ text: String) -> [Imported] {
        var out: [Imported] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line
                .split(whereSeparator: { ",;\t".contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }

            // Try "lat,lng[,name][,category]" — works whenever the
            // first two fields parse as numbers in valid coord range.
            if parts.count >= 2,
               let lat = Double(parts[0]),
               let lng = Double(parts[1]),
               (-90.0...90.0).contains(lat),
               (-180.0...180.0).contains(lng) {
                let name = parts.count >= 3 ? parts[2] : String(format: "%.5f, %.5f", lat, lng)
                let category = parts.count >= 4 ? parts[3] : ""
                out.append(Imported(name: name, lat: lat, lng: lng, category: category))
                continue
            }

            // Else try "name,lat,lng[,category]".
            if parts.count >= 3,
               let lat = Double(parts[1]),
               let lng = Double(parts[2]),
               (-90.0...90.0).contains(lat),
               (-180.0...180.0).contains(lng) {
                let name = parts[0]
                let category = parts.count >= 4 ? parts[3] : ""
                out.append(Imported(name: name, lat: lat, lng: lng, category: category))
                continue
            }

            // No coords parsed — skip. We don't fall back to "name
            // only with 0,0" because every such line is essentially
            // a typo, and silently inserting (0,0) entries pollutes
            // the bookmark list.
        }
        return out
    }
}
