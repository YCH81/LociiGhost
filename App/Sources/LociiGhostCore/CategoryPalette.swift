import Foundation

/// Colours for bookmark categories.
///
/// Categories are free-form strings the user types, binned at render
/// time — there is no category entity, and this deliberately doesn't
/// add one. A colour is a lookup keyed by the category's name, stored
/// beside the preferences rather than on a new SwiftData model: a
/// schema change here would put every launch's `ModelContainer` at
/// risk for a purely cosmetic feature, and the v1.15.2 audit's X18 was
/// about exactly that failure mode being unrecoverable.
///
/// A category with no assigned colour still gets one, derived from its
/// name, so a sidebar full of categories looks organised before anyone
/// configures anything.
public enum CategoryPalette {

    /// Ten hues, spaced around the wheel and held at a saturation and
    /// lightness that stay legible on both a near-white and a
    /// near-black ground — the sidebar and the map pins are rendered
    /// in whichever theme the user is in, and a colour that only works
    /// in one of them is a bug that only half the users see.
    public static let hexes: [String] = [
        "#C2453B",  // red
        "#D97B2B",  // orange
        "#B8912A",  // ochre
        "#6E9B3A",  // olive
        "#2F8F6B",  // green
        "#2C8AA6",  // cyan
        "#3A6EC4",  // blue
        "#6A5AC4",  // indigo
        "#9B4FB0",  // purple
        "#C24B86",  // magenta
    ]

    /// The "no category" bin. Deliberately a grey: uncategorised is an
    /// absence, and giving it a hue would make it look like a category
    /// the user chose.
    public static let uncategorisedHex = "#8A938D"

    /// Trimmed name used as the lookup key.
    ///
    /// A trailing space is invisible in the sidebar but would
    /// otherwise hash to a different colour, so "Work" and "Work "
    /// would render as two different categories that look identical.
    public static func key(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FNV-1a over the name's UTF-8 bytes.
    ///
    /// NOT `String.hashValue`: Swift seeds its hasher per process, so
    /// the auto colour would change on every launch and every machine.
    /// A backup restored on another Mac has to look like the one it
    /// came from, so the hash has to be defined by us, not by the
    /// standard library. `AutoColourIsStableAcrossProcesses` pins
    /// specific names to specific indices for that reason — if those
    /// values ever change, so does every user's sidebar.
    public static func stableIndex(for name: String) -> Int {
        let trimmed = key(for: name)
        guard !trimmed.isEmpty else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325          // FNV offset basis
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3                // FNV prime
        }
        return Int(hash % UInt64(hexes.count))
    }

    /// The colour a category gets when the user hasn't picked one.
    public static func autoHex(for name: String) -> String {
        let trimmed = key(for: name)
        guard !trimmed.isEmpty else { return uncategorisedHex }
        return hexes[stableIndex(for: trimmed)]
    }

    /// The colour to actually draw: the user's choice if they made
    /// one, otherwise the derived default.
    public static func hex(for name: String, overrides: [String: String]) -> String {
        let trimmed = key(for: name)
        if let chosen = overrides[trimmed], let ok = normalisedHex(chosen) {
            return ok
        }
        return autoHex(for: trimmed)
    }

    /// Validates and canonicalises a colour the user typed or picked.
    ///
    /// Accepts `RGB`, `RRGGBB`, with or without a leading `#`, any
    /// case; returns `#RRGGBB` upper-cased, or nil if it isn't a
    /// colour. Returning nil rather than a fallback colour matters:
    /// a malformed override should fall through to the derived
    /// colour, not silently paint everything black.
    public static func normalisedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        if s.count == 3 {
            // #abc -> #AABBCC
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 else { return nil }
        return "#" + s.uppercased()
    }

    /// Red, green, blue in 0...1, for whatever the caller draws with.
    /// Core stays free of SwiftUI/AppKit so the same values can feed a
    /// SwiftUI `Color` and an `NSColor` for the MKMapView pins without
    /// two conversions that can disagree.
    public static func components(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let norm = normalisedHex(hex) else { return nil }
        let digits = norm.dropFirst()
        guard let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255.0,
            Double((value >> 8) & 0xFF) / 255.0,
            Double(value & 0xFF) / 255.0
        )
    }
}
