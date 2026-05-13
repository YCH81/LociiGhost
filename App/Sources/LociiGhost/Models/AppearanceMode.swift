import SwiftUI

/// User-facing toggle for whether the app's accent / tint comes from
/// the LociiGhost brand palette (sage green, matches the AppIcon) or
/// from the system default (macOS's blue accent).
///
/// Settings → Appearance exposes this as a picker. Default is
/// `.system` so a fresh install looks like a Mac-native app first;
/// users who want the icon-matching sage tint can opt in.
enum AppearanceMode: String, CaseIterable, Identifiable {
    /// LociiGhost brand sage — matches the paper-plane AppIcon.
    /// Opt-in via Settings → Appearance.
    case brand
    /// macOS's system accent (typically the user's chosen Accent
    /// Colour in System Settings, falling back to blue). Default on
    /// first install / freshly hydrated prefs.
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brand:
            return String(
                localized: "Default appearance (matches icon)",
                comment: "Settings — appearance mode that follows the icon's sage palette"
            )
        case .system:
            return String(
                localized: "System appearance",
                comment: "Settings — appearance mode that uses macOS's default accent colour"
            )
        }
    }

    /// Tint colour to apply at the WindowGroup root. SwiftUI
    /// propagates this through `Environment(\.tint)`, so most
    /// built-in tinted controls inherit it automatically.
    var tint: Color {
        switch self {
        case .brand:  return Color.lociSage
        case .system: return Color.accentColor
        }
    }
}
