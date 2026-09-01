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
    /// disabled, MapKit-only behaviour.
    ///
    /// v1.15.2 audit (X8): DEPRECATED as storage. The key now lives in
    /// the Keychain (`KeychainSecret.googleDirectionsKey`); this
    /// property is kept only so an existing store can be read once
    /// and migrated, after which it is set to nil. Do not write to it.
    var googleGeocodeAPIKey: String?

    /// Whether a Google key is configured, mirrored out of the
    /// Keychain so UI that only needs a checkmark doesn't have to
    /// unlock anything. Optional with a default so SwiftData can
    /// migrate an existing store without a schema version bump.
    /// Optional rather than a defaulted Bool because SwiftData's
    /// lightweight migration is only guaranteed for optionals, and
    /// failing it here would drop the user into the in-memory
    /// fallback — losing every bookmark and route.
    var hasGoogleGeocodeAPIKey: Bool?

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

    /// Per-category bookmark colours, as a JSON object of
    /// `{"<category>": "#RRGGBB"}`.
    ///
    /// Stored as one optional String rather than a new SwiftData model
    /// on purpose. Categories are free-form strings binned at render
    /// time -- there is no category entity to hang a colour off, and
    /// introducing one would mean a schema migration and a second
    /// source of truth for a name that already lives on every
    /// bookmark. An optional scalar migrates without touching the
    /// container, which for a cosmetic feature is the right amount of
    /// risk: X18 in the last audit was the store failing to open, and
    /// that takes the whole app with it.
    ///
    /// Categories the user hasn't coloured are absent from the map and
    /// get a colour derived from their name -- see `CategoryPalette`.
    var bookmarkCategoryColorsJSON: String? = nil

    // ── v1.17: Address-search provider ──────────────────────────
    /// Raw value of `GeocodeProvider` — which service the search bar
    /// asks. "apple" (the default) is the only one with true
    /// as-you-type completion and no quota; the two OpenStreetMap
    /// services index the Chinese shop and landmark names Apple
    /// misses; "google" needs the user's own key and is shown
    /// disabled until there is one.
    ///
    /// Defaulted rather than optional so an existing store migrates
    /// without a schema version bump, same as `routingEngineRaw`.
    var geocodeProviderRaw: String = "apple"

    // ── v1.17: Flower mode ──────────────────────────────────────
    /// `FlowerConfig` as JSON. Nine numbers for one optional mode is
    /// not worth nine columns and a migration; nil means the defaults.
    var flowerSettingsJSON: String? = nil

    // ── v1.17: Group sync ───────────────────────────────────────
    /// The other iPhones that mirror the selected one, as a JSON array
    /// of udids. nil / empty means no group, which is the default and
    /// the behaviour every earlier version had.
    var groupUDIDsJSON: String? = nil

    /// Whether the group is applied. Kept apart from the list so
    /// turning it off for one run doesn't lose the user's selection.
    var groupSyncEnabled: Bool = false

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
