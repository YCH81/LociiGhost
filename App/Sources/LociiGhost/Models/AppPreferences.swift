import Foundation
import SwiftData

/// Single-instance preferences record. Phase 5.2 keeps it deliberately
/// narrow — just the four pieces of state that meaningfully change the
/// "next launch" experience:
///
///   * the map camera (so the user doesn't re-center to home each open)
///   * the active TravelProfile (driving / cycling / walking)
///   * any custom-typed speed override (overrides the profile default)
///   * the last simulated location (so the map can immediately show
///     "this is where the iPhone was" before the daemon catches up)
///
/// We deliberately do NOT persist the last-connected device's UDID —
/// the user said they prefer the manual Connect step on every launch.
///
/// The model is single-instance: `AppPreferences.fetchOrCreate(_:)`
/// returns the one row, creating it if the store is empty. SwiftData's
/// auto-save (debounced) means callers just mutate properties — no
/// explicit `save()` needed for primitive scalar updates.
@Model
final class AppPreferences {
    // ── Map camera ──────────────────────────────────────────────
    /// Center latitude of the last visible region. nil → no save yet.
    var mapCenterLat: Double?
    var mapCenterLng: Double?
    /// Span (in metres) of the last visible region — encoded as the
    /// latitudinal half-span so a single Double captures "how zoomed
    /// in we were" without storing both axes (which would over-
    /// constrain the restore).
    var mapSpanMeters: Double?

    // ── Speed / profile ─────────────────────────────────────────
    /// Last-selected TravelProfile rawValue ("walking", "cycling",
    /// "driving"). Stored as String so SwiftData's schema doesn't
    /// have to learn the enum.
    var travelProfileRaw: String

    /// Custom speed override in m/s. nil = use the travelProfile's
    /// default speed.
    var customSpeedMps: Double?

    // ── Last simulated position ─────────────────────────────────
    /// Last simulated lat/lng the desktop saw. Used to repaint the
    /// blue dot on the map immediately after relaunch (the daemon's
    /// in-memory `last_lat_lng` is also persisted to disk via the
    /// device-cache.json sibling, but mirroring it here lets the
    /// SwiftUI map render before the daemon's first `device.list`
    /// roundtrip lands).
    var lastSimulatedLat: Double?
    var lastSimulatedLng: Double?

    // ── v1.9: Route-complete alert sound ────────────────────────
    /// When true and a navigation / route-loop / random-walk run
    /// transitions to "idle" naturally (i.e. NOT via an explicit
    /// stop), play the macOS system default alert (`Glass.aiff`).
    /// Toggle in Settings. Defaults to false so a fresh install
    /// doesn't surprise users with sound on first run.
    var alertSoundEnabled: Bool = false

    // ── v1.9: Google Geocoding fallback ─────────────────────────
    /// Optional Google Geocoding API key. When set, the search bar
    /// uses Google as a fallback when MapKit's local search returns
    /// no useful matches (e.g. Chinese-language store names that
    /// Apple's geocoder struggles with). Empty / nil → Google is
    /// disabled, MapKit-only behaviour. Stored in plain text in
    /// SwiftData; the user pastes their own key.
    var googleGeocodeAPIKey: String?

    // ── v1.9.1: Routing engine picker (default changed to MapKit in v1.10) ─
    /// Which routing backend to use when planning navigation routes.
    /// Stored as the raw string of `RoutingEngine` so SwiftData's
    /// schema stays primitive. Defaults to "mapkit" — Apple MapKit
    /// resolved on the Mac side (no API key, no external rate limit,
    /// Apple-maintained map data). Other options: "osrm_demo" (the
    /// previous v1.9 default; kept for true bike-network routes),
    /// "google" (requires `googleGeocodeAPIKey` with Directions API
    /// enabled), or "straight_line" (no routing).
    var routingEngineRaw: String = "mapkit"

    // ── v1.9.4: Appearance mode (brand vs system tint) ──────────
    /// Raw string of `AppearanceMode`. "system" (default) lets every
    /// tinted element fall back to macOS's accent colour, which is
    /// what most users expect from a Mac-native app. "brand" tints
    /// the app with the LociiGhost sage palette extracted from the
    /// AppIcon. The Settings → Appearance section exposes the picker.
    var appearanceModeRaw: String = "system"

    init(
        travelProfileRaw: String = "driving"
    ) {
        self.travelProfileRaw = travelProfileRaw
    }

    /// Return the singleton row, creating it when the store is empty.
    /// All call sites should funnel through this so we never end up
    /// with two preference rows fighting each other.
    static func fetchOrCreate(_ ctx: ModelContext) -> AppPreferences {
        let descriptor = FetchDescriptor<AppPreferences>()
        if let existing = (try? ctx.fetch(descriptor))?.first {
            return existing
        }
        let fresh = AppPreferences()
        ctx.insert(fresh)
        try? ctx.save()
        return fresh
    }
}
