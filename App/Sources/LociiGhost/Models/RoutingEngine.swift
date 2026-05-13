import Foundation

/// Picker options for the v1.9.1 "Routing engine" Settings section.
///
/// Each value has a `rawValue` (stored in `AppPreferences.routingEngineRaw`)
/// and a `displayName` shown in the picker. The Mac passes the raw
/// string to the daemon in every `location.navigate` / `routing.route`
/// call; the daemon dispatches to OSRM or Google or straight-line
/// based on that.
enum RoutingEngine: String, CaseIterable, Identifiable {
    /// Apple MapKit's MKDirections, resolved on the Mac side (no
    /// daemon round-trip for routing). Default since v1.10. Bundled
    /// with macOS, no API key, Apple-maintained map data — especially
    /// good in Taiwan. Cycling routes as automobile geometry (Apple
    /// doesn't expose a bike profile); SpeedPicker still drives
    /// playback pace, matching the existing OSRM-NoRoute-fallback
    /// behaviour.
    case mapKit = "mapkit"

    /// Public OSRM demo at router.project-osrm.org — what LociiGhost
    /// used as default through v1.9.x. Kept as an opt-in for users
    /// who want true bike-network geometry or who are routing in
    /// regions where MapKit's data is weak. Rate-limited and
    /// occasionally down.
    case osrmDemo = "osrm_demo"

    /// Google Directions API. Reuses the same key field that the
    /// Google Geocoding fallback uses. Requires the user to enable
    /// "Directions API" in their Google Cloud project alongside
    /// Geocoding API. Counts against the user's Google quota.
    case google = "google"

    /// No routing — every leg is treated as a straight-line ("as the
    /// crow flies") jump. Useful for indoor / off-road / open-water
    /// scenarios where road geometry is meaningless, or as a manual
    /// fallback when every networked engine is unreachable.
    case straightLine = "straight_line"

    var id: String { rawValue }

    /// Localised label shown in the Settings picker.
    var displayName: String {
        switch self {
        case .mapKit:
            return String(localized: "Apple Maps (default)",
                          comment: "Routing engine picker — Apple MapKit option")
        case .osrmDemo:
            return String(localized: "OSRM Public Demo",
                          comment: "Routing engine picker — OSRM option")
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
        case .mapKit:
            return String(localized: "Native Apple Maps routing. No setup or API key needed. Cycling uses driving geometry — playback speed still follows the SpeedPicker.",
                          comment: "Routing engine picker — MapKit caption")
        case .osrmDemo:
            return String(localized: "Free public OSRM server. True bike-network routes; may be slow when busy or temporarily down.",
                          comment: "Routing engine picker — OSRM caption")
        case .google:
            return String(localized: "Uses your Google API key (Directions API must be enabled). Counts against quota.",
                          comment: "Routing engine picker — Google caption")
        case .straightLine:
            return String(localized: "Skips routing. The iPhone moves in straight lines between waypoints.",
                          comment: "Routing engine picker — straight-line caption")
        }
    }
}
