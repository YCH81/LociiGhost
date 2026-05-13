import Foundation

/// Resolve an ISO 3166-1 alpha-2 country code to a user-facing
/// display name + flag emoji.
///
/// Display name is locale-aware: callers pass in the SwiftUI
/// `@Environment(\.locale)` value so flipping the app language
/// picker between EN and 中文 instantly re-renders the country
/// chip in the matching language. Foundation's
/// `Locale.localizedString(forRegionCode:)` already returns short
/// common names for the major countries:
///
///   * Locale("zh-TW") → "台灣" / "美國" / "英國" / "日本"
///   * Locale("en")    → "Taiwan" / "United States" / etc.
///
/// We don't ship a hand-curated table any more — Foundation's
/// CLDR-backed strings cover every ISO code we'd plausibly see,
/// and going through `localizedString(forRegionCode:)` keeps the
/// chip honest when the user toggles the language picker mid-
/// session.
enum CountryDisplay {

    /// Resolve a display name. Tries `locale.localizedString(...)`
    /// first; falls back to whatever string the geocoder handed
    /// us (which may be in zh-TW because of how we configured
    /// `TimezoneService.context`); finally falls back to the bare
    /// ISO code so the chip always renders something.
    static func displayName(
        isoCode: String?,
        locale: Locale,
        geocoderFallback: String?,
    ) -> String {
        guard let iso = isoCode else {
            return geocoderFallback ?? "—"
        }
        if let localised = locale.localizedString(forRegionCode: iso),
           !localised.isEmpty {
            return localised
        }
        if let fb = geocoderFallback, !fb.isEmpty { return fb }
        return iso.uppercased()
    }

    /// Convert an ISO 3166-1 alpha-2 country code to the
    /// flag-emoji codepoints. Each ASCII letter maps to its
    /// Regional Indicator Symbol equivalent (U+1F1E6 + offset).
    /// Returns "🏳" (white flag) when the code is missing or
    /// malformed so the chip still has a glyph to render.
    static func flagEmoji(isoCode: String?) -> String {
        guard let iso = isoCode, iso.count == 2 else { return "🏳" }
        let base = UnicodeScalar("🇦").value - UnicodeScalar("A").value
        var s = String.UnicodeScalarView()
        for char in iso.uppercased().unicodeScalars {
            guard let scalar = UnicodeScalar(char.value + base) else {
                return "🏳"
            }
            s.append(scalar)
        }
        return String(s)
    }
}
