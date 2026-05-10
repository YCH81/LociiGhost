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
