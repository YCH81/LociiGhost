import Foundation
import CoreLocation

/// Minimal Google S2 geometry subset — just what an on-map grid
/// overlay needs. Ported from jonatkins/s2-geometry-javascript (MIT)
/// using the same cube-projection + Hilbert-curve math; the wider
/// S2 library (covering, distance queries, polygon ops) is
/// intentionally NOT included.
///
/// Public API:
///   * `latLngToKey(lat:lng:level:)` — quad-key string at a level
///   * `keyToCorners(_:)` — [SW, NW, NE, SE] (already in valid
///     simple-polygon order; the raw S2 [SW, SE, NE, NW] produces
///     a self-intersecting "bowtie" if drawn directly)
///   * `keyToCenter(_:)` — centre coord
///   * `keyToNeighbors(_:)` — 4 edge-adjacent cells
///   * `approxCellSizeMeters(level:lat:)` — for size hints + zoom
///     suppression on the renderer
///
/// **Cell identity is shared with canonical S2** even though our
/// quad-key strings use a custom Hilbert-orientation table — the
/// (face, i, j) tuple comes from the same deterministic projection
/// chain (lat/lng → xyz → face/uv → st → ij), so the same ground
/// patch is identified, just labelled differently. Useful for the
/// Pikmin Bloom L17 decor-cell case: drawing this grid on the map
/// matches Pikmin's cell boundaries exactly.
///
/// Key format: `"<face>/<positions>"` — face is 0-5 (cube faces),
/// positions is a string of `level` digits each 0-3 (Hilbert
/// quadrant per recursion level).
public enum S2Grid {
    // MARK: - Hilbert lookup tables
    //
    // The S2 spec splits each cube face into a Hilbert-curve-ordered
    // grid; at each recursion level the 4 quadrants are visited in
    // an order that depends on the parent quadrant's "orientation".
    //
    // POS_TO_IJ[orientation][position] → encoded (iBit, jBit) where
    //   encoded = (iBit << 1) | jBit  — i.e. iBit is the high bit.
    // IJ_TO_POS is the per-orientation inverse, computed by hand
    // below so the round-trip ijToKey/keyToIJ stays consistent.

    private static let POS_TO_OR: [Int] = [1, 0, 0, 3]

    private static let POS_TO_IJ: [[Int]] = [
        [0, 1, 3, 2],
        [0, 2, 3, 1],
        [3, 2, 0, 1],
        [3, 1, 0, 2],
    ]

    /// Inverse of `POS_TO_IJ`: `IJ_TO_POS[orientation][encoded] = position`.
    /// Hand-computed from POS_TO_IJ — kept as a literal rather than
    /// a `lazy` initializer so the table reads at a glance.
    private static let IJ_TO_POS: [[Int]] = [
        [0, 1, 3, 2],
        [0, 3, 1, 2],
        [2, 3, 1, 0],
        [2, 1, 3, 0],
    ]

    // MARK: - Public API

    public static func latLngToKey(lat: Double, lng: Double, level: Int) -> String {
        let (x, y, z) = latLngToXYZ(lat: lat, lng: lng)
        let (face, u, v) = xyzToFaceUV(x: x, y: y, z: z)
        let s = uvToST(u)
        let t = uvToST(v)
        let (i, j) = stToIJ(s: s, t: t, level: level)
        return ijToKey(face: face, i: i, j: j, level: level)
    }

    public static func keyToCenter(_ key: String) -> CLLocationCoordinate2D {
        let (face, i, j, level) = keyToIJ(key)
        let cellSize = 1.0 / Double(1 << level)
        let s = (Double(i) + 0.5) * cellSize
        let t = (Double(j) + 0.5) * cellSize
        let u = stToUV(s)
        let v = stToUV(t)
        let (x, y, z) = faceUVToXYZ(face: face, u: u, v: v)
        let (lat, lng) = xyzToLatLng(x: x, y: y, z: z)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// 4 cell corners in [SW, NW, NE, SE] order — directly usable as
    /// an MKPolygon / MapPolygon coordinate ring. The Leaflet-side
    /// port mentioned this re-ordering as "the first thing to verify";
    /// raw S2 returns [SW, SE, NE, NW] which produces a self-
    /// intersecting "bowtie" when drawn.
    public static func keyToCorners(_ key: String) -> [CLLocationCoordinate2D] {
        let (face, i, j, level) = keyToIJ(key)
        let cellSize = 1.0 / Double(1 << level)
        let s0 = Double(i) * cellSize
        let t0 = Double(j) * cellSize
        let s1 = s0 + cellSize
        let t1 = t0 + cellSize
        // (s, t) corners as [SW, NW, NE, SE]:
        let cornerST: [(Double, Double)] = [
            (s0, t0), // SW
            (s0, t1), // NW
            (s1, t1), // NE
            (s1, t0), // SE
        ]
        return cornerST.map { st in
            let u = stToUV(st.0)
            let v = stToUV(st.1)
            let (x, y, z) = faceUVToXYZ(face: face, u: u, v: v)
            let (lat, lng) = xyzToLatLng(x: x, y: y, z: z)
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
    }

    /// 4 edge-adjacent cells' quad keys. When the offset stays on the
    /// same cube face we encode the neighbour directly from (i±1, j)
    /// or (i, j±1); when it crosses the face boundary we round-trip
    /// through `(s, t) → (u, v) → xyz → lat/lng → key` so the proper
    /// neighbouring face's key falls out without us hard-coding the
    /// S2 face-neighbour tables.
    public static func keyToNeighbors(_ key: String) -> [String] {
        let (face, i, j, level) = keyToIJ(key)
        let maxIJ = (1 << level) - 1
        let offsets: [(Int, Int)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        return offsets.map { (di, dj) in
            let ni = i + di
            let nj = j + dj
            if ni >= 0, ni <= maxIJ, nj >= 0, nj <= maxIJ {
                return ijToKey(face: face, i: ni, j: nj, level: level)
            }
            // Off-face: project the would-be neighbour's centre back
            // to lat/lng and re-encode.
            let cellSize = 1.0 / Double(1 << level)
            let s = (Double(ni) + 0.5) * cellSize
            let t = (Double(nj) + 0.5) * cellSize
            let u = stToUV(max(0, min(1, s)))
            let v = stToUV(max(0, min(1, t)))
            let (x, y, z) = faceUVToXYZ(face: face, u: u, v: v)
            let (lat, lng) = xyzToLatLng(x: x, y: y, z: z)
            return latLngToKey(lat: lat, lng: lng, level: level)
        }
    }

    /// Approximate cell side length in metres at the given level and
    /// latitude. Used for size-hint UI ("≈ 76 m") and for the zoom
    /// suppression rule on the renderer (skip drawing when the cell
    /// would be smaller than ~2 px).
    public static func approxCellSizeMeters(level: Int, lat: Double) -> Double {
        let cellsPerSide = Double(1 << level)
        // Earth circumference ÷ 4 — each cube face spans roughly that
        // along its principal axis at the equator.
        let equatorMeters = 40_075_016.686 / 4.0
        let latFactor = cos(lat * .pi / 180)
        return (equatorMeters / cellsPerSide) * latFactor
    }

    // MARK: - Lower-level math (exposed `internal` for unit tests)

    static func latLngToXYZ(lat: Double, lng: Double) -> (Double, Double, Double) {
        let d2r = Double.pi / 180.0
        let phi = lat * d2r
        let theta = lng * d2r
        let cosPhi = cos(phi)
        return (cos(theta) * cosPhi, sin(theta) * cosPhi, sin(phi))
    }

    static func xyzToLatLng(x: Double, y: Double, z: Double) -> (Double, Double) {
        let r2d = 180.0 / Double.pi
        let lat = atan2(z, sqrt(x * x + y * y)) * r2d
        let lng = atan2(y, x) * r2d
        return (lat, lng)
    }

    /// (x, y, z) on unit sphere → (face 0–5, u ∈ [-1, 1], v ∈ [-1, 1])
    /// per S2's cube-projection convention. The dominant component
    /// picks the face; the other two are projected onto that face's
    /// principal axes.
    static func xyzToFaceUV(x: Double, y: Double, z: Double) -> (Int, Double, Double) {
        let absX = abs(x), absY = abs(y), absZ = abs(z)
        let face: Int
        if absX >= absY, absX >= absZ {
            face = x > 0 ? 0 : 3
        } else if absY >= absX, absY >= absZ {
            face = y > 0 ? 1 : 4
        } else {
            face = z > 0 ? 2 : 5
        }
        let u: Double
        let v: Double
        switch face {
        case 0: u = y / x;  v = z / x
        case 1: u = -x / y; v = z / y
        case 2: u = -x / z; v = -y / z
        case 3: u = z / x;  v = y / x
        case 4: u = z / y;  v = -x / y
        case 5: u = -y / z; v = -x / z
        default: u = 0; v = 0
        }
        return (face, u, v)
    }

    /// Inverse of `xyzToFaceUV`: (face, u, v) → unit sphere xyz.
    static func faceUVToXYZ(face: Int, u: Double, v: Double) -> (Double, Double, Double) {
        switch face {
        case 0: return (1, u, v)
        case 1: return (-u, 1, v)
        case 2: return (-u, -v, 1)
        case 3: return (-1, -v, -u)
        case 4: return (v, -1, -u)
        case 5: return (v, u, -1)
        default: return (0, 0, 0)
        }
    }

    /// (s ∈ [0, 1]) → (u ∈ [-1, 1]) via S2's quadratic projection.
    /// Reduces the area distortion vs. a plain linear map.
    static func stToUV(_ s: Double) -> Double {
        return s >= 0.5
            ? (1.0 / 3.0) * (4.0 * s * s - 1.0)
            : (1.0 / 3.0) * (1.0 - 4.0 * (1.0 - s) * (1.0 - s))
    }

    /// Inverse of `stToUV`.
    static func uvToST(_ u: Double) -> Double {
        return u >= 0
            ? 0.5 * sqrt(1.0 + 3.0 * u)
            : 1.0 - 0.5 * sqrt(1.0 - 3.0 * u)
    }

    // MARK: - Hilbert encoding

    /// (s, t) ∈ [0, 1] → (i, j) integer cell indices at `level`.
    /// Each axis is split into 2^level segments; clamps at the edges
    /// so a point exactly on s=1 stays in the last cell instead of
    /// overflowing into the off-face "cell 2^level".
    static func stToIJ(s: Double, t: Double, level: Int) -> (Int, Int) {
        let maxIJ = 1 << level
        let i = max(0, min(maxIJ - 1, Int(s * Double(maxIJ))))
        let j = max(0, min(maxIJ - 1, Int(t * Double(maxIJ))))
        return (i, j)
    }

    /// (face, i, j) → Hilbert quad key. Walks from root to leaf,
    /// emitting the position 0–3 at each recursion level and
    /// updating the orientation for the next level.
    static func ijToKey(face: Int, i: Int, j: Int, level: Int) -> String {
        var positions = ""
        positions.reserveCapacity(level)
        var orientation = 0
        for d in (0..<level).reversed() {
            let iBit = (i >> d) & 1
            let jBit = (j >> d) & 1
            let ijIndex = (iBit << 1) | jBit
            let pos = IJ_TO_POS[orientation][ijIndex]
            positions += String(pos)
            orientation ^= POS_TO_OR[pos]
        }
        return "\(face)/\(positions)"
    }

    /// Inverse of `ijToKey`. Returns `(face, i, j, level)`.
    static func keyToIJ(_ key: String) -> (Int, Int, Int, Int) {
        let parts = key.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let face = Int(parts[0])
        else { return (0, 0, 0, 0) }
        let positions = parts[1]
        let level = positions.count
        var i = 0
        var j = 0
        var orientation = 0
        for ch in positions {
            guard let pos = ch.wholeNumberValue, pos >= 0, pos <= 3 else { continue }
            let ij = POS_TO_IJ[orientation][pos]
            let iBit = (ij >> 1) & 1
            let jBit = ij & 1
            i = (i << 1) | iBit
            j = (j << 1) | jBit
            orientation ^= POS_TO_OR[pos]
        }
        return (face, i, j, level)
    }
}
