import Foundation
import SwiftData

/// Saved location the user can re-teleport to with one click.
/// Phase 5.3 keeps this minimal — name, position, optional category
/// for grouping in the sidebar, optional SF Symbol name for visual
/// distinction. Created and edited entirely through SwiftData
/// `ModelContext`; the sidebar binds to a `@Query` of these.
@Model
final class Bookmark {
    /// User-visible name, e.g. "Home", "台北 101", "Office 上班路線終點".
    var name: String
    var lat: Double
    var lng: Double
    /// Free-form category. Sidebar groups bookmarks by category and
    /// shows them as collapsible sections; an empty string means
    /// "uncategorised" (the sidebar puts those at the top).
    var category: String
    /// SF Symbol name. Defaults to a generic pin so a bookmark
    /// added with no chosen icon still renders cleanly.
    var iconSymbol: String
    /// When the user added this bookmark. Used for sort order
    /// (newest first within a category) and lets us show a "added
    /// today / yesterday / N days ago" label later if needed.
    var createdAt: Date

    init(
        name: String,
        lat: Double,
        lng: Double,
        category: String = "",
        iconSymbol: String = "mappin.circle.fill",
        createdAt: Date = .now
    ) {
        self.name = name
        self.lat = lat
        self.lng = lng
        self.category = category
        self.iconSymbol = iconSymbol
        self.createdAt = createdAt
    }
}
