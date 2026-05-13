import Foundation
import SwiftData

/// One entry in the "Recent Places" capsule shown on the map. Each
/// time the user teleports, navigates, searches, or coordinate-jumps,
/// we append a row here so they can one-click back to where they've
/// been recently — even across app launches.
///
/// Capped at ~50 rows total: when the count exceeds the cap during
/// `AppState.recordRecentPlace(...)`, the oldest entries are pruned.
/// 50 is a sweet spot — long enough for "the place I jumped to
/// yesterday" but short enough that the popover list never needs
/// internal scrolling for a casual user.
@Model
final class RecentPlace {
    /// Display name. For search results this is the user's query
    /// (or the resolved place name when geocoding succeeded). For
    /// raw coord taps it's the lat/lng formatted to 5dp.
    var label: String
    var lat: Double
    var lng: Double
    /// What the user did to create this entry. Drives the icon and
    /// the "back" action — a teleport row re-teleports, a navigate
    /// row re-plans navigation, etc. Stored as the raw string so
    /// SwiftData's schema doesn't have to learn the enum.
    var kindRaw: String
    /// When this happened. Used for sort order (newest first) and
    /// for the "5m ago / yesterday" relative-time labels.
    var createdAt: Date

    init(
        label: String,
        lat: Double,
        lng: Double,
        kind: Kind,
        createdAt: Date = .now
    ) {
        self.label = label
        self.lat = lat
        self.lng = lng
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
    }

    var kind: Kind {
        Kind(rawValue: kindRaw) ?? .teleport
    }

    /// What action produced this entry. The icon + verb shown in the
    /// popover row come from here, as does the "tap row" behaviour:
    /// teleport / coord rows immediately re-teleport, search rows
    /// re-teleport (the resolved location), navigate rows re-plan
    /// navigation to the same target.
    enum Kind: String, CaseIterable, Codable {
        case teleport
        case navigate
        case search
        case coord

        /// SF Symbol name used in the popover. Keep these small + flat
        /// — they sit in a 24pt circle next to a single-line label.
        var symbol: String {
            switch self {
            case .teleport: return "scope"
            case .navigate: return "arrow.triangle.turn.up.right.circle"
            case .search:   return "magnifyingglass"
            case .coord:    return "circle.grid.cross"
            }
        }
    }
}
