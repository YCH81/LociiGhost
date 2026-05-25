import Foundation

/// v1.11.2: serialised backup of every user-generated entity worth
/// preserving across a clean reinstall — bookmarks, routes, stop
/// presets. Settings / preferences are intentionally NOT included
/// (those are tied to a specific macOS UserDefaults domain and most
/// of them — language, theme, geocoder API key — are either trivially
/// re-set or genuinely machine-specific).
///
/// The `version` field exists so future schema changes can be detected
/// and migrated, or refused cleanly with a "this backup is from a
/// newer LociiGhost — please update" error. Schema v1 is the initial
/// shape; bump on any field rename or semantic change.
struct FullBackupBundle: Codable {
    /// Schema version. Bump when the wire shape changes.
    let version: Int
    /// When this backup was produced. ISO8601 string in the JSON.
    let exportedAt: Date

    let bookmarks: [BookmarkEntry]
    let routes: [RouteEntry]
    let stopPresets: [StopPresetEntry]

    struct BookmarkEntry: Codable {
        let name: String
        let lat: Double
        let lng: Double
        let category: String
        let iconSymbol: String
        /// Original createdAt for sort-order preservation. Optional
        /// because older clients / hand-rolled backups may omit it;
        /// the importer falls back to `.now` so the entry still
        /// lands in the database.
        let createdAt: Date?
    }

    struct RouteEntry: Codable {
        let name: String
        let category: String
        let iconSymbol: String
        /// `[[lat, lng], [lat, lng], ...]` — flat array-of-pairs so
        /// the JSON stays compact and is human-readable when opened
        /// in a text editor. Mirrors GPX's two-number-per-point feel.
        let points: [[Double]]
        let createdAt: Date?
    }

    struct StopPresetEntry: Codable {
        let name: String
        let points: [[Double]]
        let createdAt: Date?
    }
}

/// Behaviour when importing an existing backup into a database that
/// already contains records.
///
/// * `.overwrite` — wipe every existing bookmark / route / preset
///   first, then insert from the backup. Drastic but clean — the
///   user's state ends up identical to whatever was exported.
/// * `.merge` — keep existing records, append backup entries whose
///   `(name, coords)` key isn't already present. Safe for "I want
///   to pull in a friend's bookmark export without losing mine."
enum BackupImportStrategy {
    case overwrite
    case merge
}
