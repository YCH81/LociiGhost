import Foundation

/// The six flower shapes a bookmark pin can take.
///
/// Drawn from parameters rather than shipped as image assets: the pin
/// is rendered at three sizes in two renderers (the SwiftUI map's
/// marker, the MKMapView glyph, and the sidebar row), and a raster
/// asset would need a set per size per renderer. Geometry also lets
/// the shape take the category's colour, which is the other half of
/// making 3 000 pins readable -- six shapes times ten category colours
/// is sixty combinations you can tell apart at a glance.
///
/// A petal is one or two overlapping discs offset from the centre.
/// That sounds crude and is exactly why it reads as "cute": round,
/// chunky lobes with no sharp corners, which is what a flower drawn
/// for a map pin at 22 points needs to be. Two lobes give the notched
/// tip that separates a cherry blossom from a daisy.
public enum FlowerPin {

    /// One flower's geometry. Everything is a fraction of the pin's
    /// radius so the same numbers work at any size.
    public struct Design: Sendable, Equatable, Identifiable {
        /// Stable identifier. **Persisted on every bookmark that uses
        /// it**, so renaming one silently repaints part of the user's
        /// map -- see `DesignIDsAreStable` in the tests.
        public let id: String
        /// Non-localised English name; the UI localises from the id.
        public let name: String
        /// How many petals go round the centre.
        public let petals: Int
        /// Distance from the flower's centre to each petal's centre.
        public let petalDistance: Double
        /// Radius of one petal lobe.
        public let petalRadius: Double
        /// 1 = a single round petal. 2 = two discs side by side, which
        /// makes the notched tip of a cherry blossom or a clover leaf.
        public let lobes: Int
        /// Angular gap between the two lobes, in radians. Ignored when
        /// `lobes == 1`.
        public let lobeSpread: Double
        /// Radius of the centre disc. 0 draws no centre.
        public let centreRadius: Double
        /// Rotation of the whole flower, in degrees. Only cosmetic —
        /// it stops every design from pointing the same way.
        public let rotationDegrees: Double
    }

    /// The catalogue. Order is the order the picker shows.
    public static let designs: [Design] = [
        Design(id: "daisy",     name: "Daisy",
               petals: 5,  petalDistance: 0.52, petalRadius: 0.30,
               lobes: 1, lobeSpread: 0,     centreRadius: 0.22, rotationDegrees: -90),
        Design(id: "sakura",    name: "Cherry blossom",
               petals: 5,  petalDistance: 0.50, petalRadius: 0.24,
               lobes: 2, lobeSpread: 0.42,  centreRadius: 0.18, rotationDegrees: -90),
        Design(id: "tulip",     name: "Tulip",
               petals: 3,  petalDistance: 0.46, petalRadius: 0.36,
               lobes: 1, lobeSpread: 0,     centreRadius: 0,    rotationDegrees: -90),
        Design(id: "sunflower", name: "Sunflower",
               petals: 12, petalDistance: 0.60, petalRadius: 0.18,
               lobes: 1, lobeSpread: 0,     centreRadius: 0.42, rotationDegrees: 0),
        Design(id: "clover",    name: "Clover",
               petals: 4,  petalDistance: 0.44, petalRadius: 0.26,
               lobes: 2, lobeSpread: 0.55,  centreRadius: 0.10, rotationDegrees: -90),
        Design(id: "plum",      name: "Plum blossom",
               petals: 5,  petalDistance: 0.46, petalRadius: 0.36,
               lobes: 1, lobeSpread: 0,     centreRadius: 0.16, rotationDegrees: -18),
    ]

    /// The default for a bookmark that has never been given one.
    public static var fallback: Design { designs[0] }

    /// Prefix marking a `Bookmark.iconSymbol` as a flower rather than
    /// an SF Symbol name.
    ///
    /// Reusing the existing field instead of adding one keeps this off
    /// the SwiftData schema entirely, and bookmarks created before
    /// v1.17 keep rendering their SF Symbol because their value simply
    /// doesn't carry the prefix.
    public static let symbolPrefix = "flower."

    /// The stored form of a design, for `Bookmark.iconSymbol`.
    public static func storedSymbol(for design: Design) -> String {
        symbolPrefix + design.id
    }

    /// Reads a stored `iconSymbol`. Returns nil when the value is an
    /// SF Symbol name (i.e. a pre-v1.17 bookmark, or one the user set
    /// to a symbol), so the caller renders that instead.
    ///
    /// An unrecognised flower id falls back rather than returning nil:
    /// `flower.` was clearly meant to be a flower, and a pin that
    /// vanishes because a design was renamed is worse than one that
    /// shows the wrong flower.
    public static func design(forStoredSymbol raw: String) -> Design? {
        guard raw.hasPrefix(symbolPrefix) else { return nil }
        let id = String(raw.dropFirst(symbolPrefix.count))
        return designs.first { $0.id == id } ?? fallback
    }

    /// Centres and radii of every disc making up the flower, in a unit
    /// circle centred on the origin: `(x, y, r)` with x, y and r all
    /// fractions of the pin radius.
    ///
    /// Shared so the SwiftUI `Shape` and the AppKit glyph renderer
    /// draw from one set of numbers. Two renderers computing the same
    /// petals separately is how they end up subtly different — which
    /// is the P12 lesson from the last audit, in miniature.
    public static func discs(for design: Design) -> [(x: Double, y: Double, r: Double)] {
        var out: [(x: Double, y: Double, r: Double)] = []
        let base = design.rotationDegrees * .pi / 180
        let step = (2 * Double.pi) / Double(max(1, design.petals))
        for i in 0..<max(1, design.petals) {
            let theta = base + step * Double(i)
            if design.lobes >= 2 {
                for side in [-1.0, 1.0] {
                    let a = theta + side * design.lobeSpread / 2
                    out.append((cos(a) * design.petalDistance,
                                sin(a) * design.petalDistance,
                                design.petalRadius))
                }
            } else {
                out.append((cos(theta) * design.petalDistance,
                            sin(theta) * design.petalDistance,
                            design.petalRadius))
            }
        }
        return out
    }
}
