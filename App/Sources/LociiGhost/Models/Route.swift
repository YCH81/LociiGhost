import Foundation
import SwiftData

/// User-saved multi-point route — typically the result of a GPX import
/// of a recorded track (hundreds of points). Like `Bookmark` but stores
/// an ORDERED LIST of coordinates instead of a single point.
///
/// Why a separate entity instead of just dropping the imported points
/// into `pendingStops` like Phase 5.4 originally did?
///
///   * GPX recordings of real outdoor activities routinely run to
///     several hundred trkpts (a 274-point Tokyo walk crashed the
///     pendingStops UI in v1.2.0). We want to keep the ENTIRE track,
///     not throw 90% away in a downsample.
///   * Multi-stop staging is for compose-and-go ad-hoc trips. A
///     persisted route is a different mental model: "I have this
///     recorded path, replay it on demand." Different storage,
///     different sidebar surface, different click-to-execute flow.
///   * Bookmarks already prove the pattern works — sidebar list,
///     right-click edit, click → execute. Route reuses every bit
///     of that ergonomics, just for a polyline instead of a pin.
///
/// Storage: the coordinate list is JSON-encoded into a single `String`
/// rather than a SwiftData relationship. SwiftData CAN store ordered
/// `[Coordinate]` if Coordinate is `@Model` too, but that means an
/// owned-objects table with N rows per imported track — expensive
/// inserts for a 1000-pt track and pointless query overhead given we
/// always read the whole list as a unit. JSON column is one row, one
/// migration-free encoding.
@Model
final class Route {
    /// User-visible name. Pre-filled from the GPX filename on import,
    /// editable via the same sheet pattern bookmarks use.
    var name: String

    /// Optional grouping label, mirrors `Bookmark.category`. Empty
    /// string means uncategorised; the sidebar lifts those to the top.
    var category: String

    /// SF Symbol name shown in the sidebar row. Defaults to a generic
    /// path-shaped glyph so a bare import still renders cleanly.
    var iconSymbol: String

    /// JSON-encoded `[Coordinate]`. We keep the encoded form on disk so
    /// schema migrations stay cheap; the Swift API exposes a typed
    /// `points` getter / setter that hides the encode/decode.
    var pointsJSON: String

    /// Cached point count so list rows don't have to decode the whole
    /// blob just to render "(274 pts)". Kept in sync by the points
    /// setter — if you mutate `pointsJSON` directly you'll desync this,
    /// so don't.
    var pointCount: Int

    /// 0-based index of the last stop the simulated location was
    /// snapped to during this route's most recent play. `0` is the
    /// canonical "no progress" sentinel (also what a freshly imported
    /// route starts with) AND the value we reset to when a play ends
    /// naturally — the StartRouteSheet's "Resume" picker option treats
    /// 0 as "no saved progress" and disables itself. The value is
    /// written by `AppState.flushRouteProgress` on a throttled timer
    /// during navigate playback and immediately on user Stop, so a
    /// mid-walk app crash loses at most ~2 s of progress. Default
    /// value 0 means SwiftData auto-migrates existing rows without a
    /// schema mismatch.
    var lastPlayedStopIndex: Int = 0

    var createdAt: Date

    init(
        name: String,
        points: [Coordinate],
        category: String = "",
        iconSymbol: String = "point.bottomleft.forward.to.point.topright.scurvepath.fill",
        createdAt: Date = .now
    ) {
        self.name = name
        self.category = category
        self.iconSymbol = iconSymbol
        self.createdAt = createdAt
        // Encode through the same helper the setter uses so the JSON
        // shape is consistent and pointCount stays accurate.
        let encoded = (try? JSONEncoder().encode(points)) ?? Data()
        self.pointsJSON = String(data: encoded, encoding: .utf8) ?? "[]"
        self.pointCount = points.count
    }

    /// Decode the persisted JSON back into a usable list. Returns an
    /// empty array if the blob is corrupt — the click-to-execute flow
    /// no-ops on empty rather than crashing.
    var points: [Coordinate] {
        get {
            guard let data = pointsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Coordinate].self, from: data)) ?? []
        }
        set {
            let encoded = (try? JSONEncoder().encode(newValue)) ?? Data()
            pointsJSON = String(data: encoded, encoding: .utf8) ?? "[]"
            pointCount = newValue.count
        }
    }
}
