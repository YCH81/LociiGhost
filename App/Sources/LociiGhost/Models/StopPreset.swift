import Foundation
import SwiftData

/// User-saved list of multi-stop coordinates — like a "favourite" for
/// the Multi-Stop panel. v1.11.0 addition.
///
/// **Why a separate entity instead of reusing `Route`?**
///
/// `Route` is for replay-this-recorded-track flows: GPX imports, sidebar
/// listing, click → "Start route?" sheet with auto-loop. Stop presets
/// are a different mental model: "I've staged 12 points for downtown
/// Tokyo; let me save them as a named set so I can reload the same
/// staging next week." The click flow is also different — see the
/// `LoadPresetSheet` confirmation (Cancel / Display / Execute) versus
/// `Route`'s direct-run sheet. Two surfaces, two semantics, two
/// entities — cleaner than overloading `Route` with a UX-mode flag.
///
/// Storage mirrors `Route` exactly: the coordinate list is JSON-encoded
/// into a single `String` column so the schema migration story stays
/// cheap (no per-point owned-objects table).
@Model
final class StopPreset {
    /// User-visible name. Required at save time — no auto-naming, so
    /// the sidebar list reads as deliberate human-authored entries
    /// instead of "Untitled 1 / Untitled 2 / ...".
    var name: String

    /// JSON-encoded `[Coordinate]`. Keeps the encoded form on disk so
    /// schema migrations stay cheap; the Swift API exposes a typed
    /// `coordinates` getter / setter that hides the encode / decode.
    var coordinatesJSON: String

    /// Cached point count so list rows don't have to decode the whole
    /// blob just to render "12 stops". Kept in sync by the
    /// `coordinates` setter; if you mutate `coordinatesJSON` directly
    /// you'll desync, so don't.
    var stopCount: Int

    var createdAt: Date

    init(
        name: String,
        coordinates: [Coordinate],
        createdAt: Date = .now,
    ) {
        self.name = name
        self.createdAt = createdAt
        let encoded = (try? JSONEncoder().encode(coordinates)) ?? Data()
        self.coordinatesJSON = String(data: encoded, encoding: .utf8) ?? "[]"
        self.stopCount = coordinates.count
    }

    /// Decode the persisted JSON back into a usable list. Returns an
    /// empty array if the blob is corrupt — the click-to-load flow
    /// no-ops on empty rather than crashing.
    var coordinates: [Coordinate] {
        get {
            guard let data = coordinatesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Coordinate].self, from: data)) ?? []
        }
        set {
            let encoded = (try? JSONEncoder().encode(newValue)) ?? Data()
            coordinatesJSON = String(data: encoded, encoding: .utf8) ?? "[]"
            stopCount = newValue.count
        }
    }
}
