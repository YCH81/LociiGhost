import Foundation

/// Picker options for the v1.9.1 "Routing engine" Settings section.
///
/// Each value has a `rawValue` (stored in `AppPreferences.routingEngineRaw`)
/// and a `displayName` shown in the picker. The Mac passes the raw
/// string to the daemon in every `location.navigate` / `routing.route`
/// call; the daemon dispatches to OSRM or Google or straight-line
/// based on that.
enum RoutingEngine: String, CaseIterable, Identifiable {
    /// Public OSRM demo at router.project-osrm.org — what LociiGhost
    /// has been using since v1.0. The only option that needs zero
    /// configuration; rate-limited and occasionally down.
    case osrmDemo = "osrm_demo"

    /// Google Directions API. Reuses the same key field that the
    /// Google Geocoding fallback uses. Requires the user to enable
    /// "Directions API" in their Google Cloud project alongside
    /// Geocoding API. More reliable than OSRM demo but counts
    /// against the user's Google quota.
    case google = "google"

    /// No routing — every leg is treated as a straight-line ("as the
    /// crow flies") jump. Useful for indoor / off-road / open-water
    /// scenarios where road geometry is meaningless, or as a manual
    /// fallback when both OSRM and Google are unreachable.
    case straightLine = "straight_line"

    var id: String { rawValue }

    /// Localised label shown in the Settings picker.
    var displayName: String {
        switch self {
        case .osrmDemo:
            return String(localized: "OSRM Public Demo (default)",
                          comment: "Routing engine picker — default OSRM option")
        case .google:
            return String(localized: "Google Directions",
                          comment: "Routing engine picker — Google option")
        case .straightLine:
            return String(localized: "Straight line (no routing)",
                          comment: "Routing engine picker — straight-line option")
        }
    }

    /// One-line caption shown under the picker explaining what the
    /// selected engine actually does.
    var caption: String {
        switch self {
        case .osrmDemo:
            return String(localized: "Free public OSRM server. No setup needed; may be slow when busy.",
                          comment: "Routing engine picker — OSRM caption")
        case .google:
            return String(localized: "Uses your Google API key (Directions API must be enabled). Best quality, counts against quota.",
                          comment: "Routing engine picker — Google caption")
        case .straightLine:
            return String(localized: "Skips routing. The iPhone moves in straight lines between waypoints.",
                          comment: "Routing engine picker — straight-line caption")
        }
    }
}
