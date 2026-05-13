import Foundation
import CoreLocation

/// Reverse-geocode a coordinate to BOTH the local timezone AND the
/// country it sits in. We bundled the two requests into a single
/// service because they come from the same CLPlacemark — no point
/// hitting Apple's geocoder twice when one round-trip yields both.
///
/// CLGeocoder is rate-limited by Apple to "a small number of
/// requests per minute"; we only fire on teleport / route start /
/// significant simulated-location moves, never per map pan.
///
/// Naming kept as `TimezoneService` for git-history continuity even
/// though the surface is broader — most callers really do just want
/// the timezone, and the country accessor is a free side-effect.
enum TimezoneService {
    /// Combined geo context for a coordinate. Each field is
    /// independently optional — Apple may give us the country but
    /// not the timezone (or vice versa) on edge geocodes near
    /// territorial boundaries.
    struct GeoContext: Sendable {
        let timezone: TimeZone?
        /// Two-letter ISO 3166-1 alpha-2 (e.g. "TW", "US", "JP").
        /// Used as the lookup key for `CountryDisplay`.
        let isoCountryCode: String?
        /// Apple's localised country name (e.g. "中華民國" with
        /// preferredLocale = zh-TW). Fallback for ISO codes we
        /// don't have a hand-curated short name for.
        let localisedCountryName: String?
    }

    /// Convenience for callers that only want the timezone — same
    /// signature as the original `timezone(forLat:lng:)` so existing
    /// call sites keep working.
    static func timezone(forLat lat: Double, lng: Double) async throws -> TimeZone {
        let ctx = await context(forLat: lat, lng: lng)
        if let tz = ctx.timezone { return tz }
        throw TimezoneError.notFound
    }

    /// Reverse-geocode and return everything we can extract. Always
    /// returns a `GeoContext` (with all-nil fields if the geocode
    /// fails) rather than throwing — the status bar's country chip
    /// shows a placeholder either way, no point making the call site
    /// handle errors.
    static func context(forLat lat: Double, lng: Double) async -> GeoContext {
        let location = CLLocation(latitude: lat, longitude: lng)
        // Force zh-TW so the placemark country comes back as
        // "中華民國" / "美利堅合眾國" / etc. — `CountryDisplay` then
        // remaps the verbose forms to short common names. For
        // countries we don't have a remapping for, the localised
        // string is what the user sees.
        let placemarks = (try? await CLGeocoder().reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "zh-TW"),
        )) ?? []
        let pm = placemarks.first
        return GeoContext(
            timezone: pm?.timeZone,
            isoCountryCode: pm?.isoCountryCode,
            localisedCountryName: pm?.country,
        )
    }
}

enum TimezoneError: LocalizedError {
    case notFound
    var errorDescription: String? {
        switch self {
        case .notFound: return "timezone: no placemark for coordinate"
        }
    }
}
