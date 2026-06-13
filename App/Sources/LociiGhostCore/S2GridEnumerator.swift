import Foundation
import CoreLocation

/// BFS-based enumeration of S2 cells whose bounding box intersects a
/// rectangular lat/lng viewport. Sits on top of `S2Grid`'s pure math.
///
/// Algorithm (mirrors the Leaflet reference port):
///
/// 1. Seed the queue with the cell containing the viewport's centre
///    (it's guaranteed to be inside the viewport — centres always
///    are — so it's a valid starting point).
/// 2. Pop a cell. Compute its lat/lng AABB from `S2Grid.keyToCorners`.
///    If it doesn't intersect the viewport, drop it AND skip its
///    neighbours. (The reference says "expand anyway" but for our
///    convex rectangular viewports the boundary-only flood from
///    intersecting cells produces the same result with no wasted
///    work — and matches what the user actually sees.)
/// 3. If it does intersect, keep it and push its 4 edge-neighbours
///    (de-duplicated through `seen`).
/// 4. Per-level cap stops runaway growth (4 000 cells at L17, ramping
///    up to 10 000 at L20). The renderer is the bottleneck above
///    that, and the UI shows a "zoom in" hint when we hit the cap.
public enum S2GridEnumerator {

    /// Per-level cap on the number of cells we'll enumerate. Sized so
    /// the renderer (MKPolygon / MapPolygon) stays responsive at the
    /// usual desktop window dimensions. Roughly half the reference
    /// Leaflet port's caps — MapKit's polygon renderer is heavier
    /// than Leaflet's SVG path renderer and the SwiftUI Map content
    /// diff multiplies polygon count by every body eval, so the
    /// upper bound has to be tighter than the algorithmic limit.
    public static func capForLevel(_ level: Int) -> Int {
        switch level {
        case ...13: return 500
        case 14:    return 1_000
        case 15, 16: return 1_500
        case 17:    return 2_000
        case 18:    return 3_000
        case 19:    return 4_000
        default:    return 5_000
        }
    }

    public struct Cell: Sendable {
        public let key: String
        /// Already in `[SW, NW, NE, SE]` polygon-ready order.
        public let corners: [CLLocationCoordinate2D]

        public init(key: String, corners: [CLLocationCoordinate2D]) {
            self.key = key
            self.corners = corners
        }
    }

    /// Result of an enumeration pass.
    public struct Result: Sendable {
        public let cells: [Cell]
        /// True when the enumerator hit the level's cap. Callers can
        /// show "zoom in to see all cells" UI in that case.
        public let cappedOut: Bool

        public init(cells: [Cell], cappedOut: Bool) {
            self.cells = cells
            self.cappedOut = cappedOut
        }
    }

    // MARK: - Grid lines (scanline polylines)

    /// Per-line content of the grid overlay. Each entry is a sequence
    /// of lat/lng waypoints that form a single horizontal or vertical
    /// scanline traversing the full viewport.
    public struct GridLines: Sendable {
        public let lines: [[CLLocationCoordinate2D]]
        /// Level the renderer should label / believe it's showing.
        /// When the user requested a fine level for a wide viewport
        /// we auto-coarsen down to whatever fits the scanline cap;
        /// `effectiveLevel < requestedLevel` indicates that happened
        /// and the UI may want to surface a "zoom in to see L17"
        /// hint.
        public let effectiveLevel: Int
        public let requestedLevel: Int
        public let suppressedReason: SuppressionReason?

        public var wasCoarsened: Bool { effectiveLevel < requestedLevel }

        public init(
            lines: [[CLLocationCoordinate2D]],
            effectiveLevel: Int,
            requestedLevel: Int,
            suppressedReason: SuppressionReason?,
        ) {
            self.lines = lines
            self.effectiveLevel = effectiveLevel
            self.requestedLevel = requestedLevel
            self.suppressedReason = suppressedReason
        }
    }

    public enum SuppressionReason: Sendable, Equatable {
        /// Viewport straddles cube faces too much to project onto the
        /// centre's face. Currently a hard bail — the user is zoomed
        /// out far enough that they wouldn't read the grid anyway.
        case multiFace
    }

    /// Build the minimal set of polylines (horizontal + vertical
    /// scanlines) covering the viewport at `level`. ALL renderer
    /// paths go through this — the BFS variant below is kept for
    /// future "which cells am I covering?" features but isn't on
    /// the per-frame path any more.
    public static func gridLines(
        viewport: ViewportBounds,
        level: Int,
        scanlineCap: Int = 300,
    ) -> GridLines {
        precondition(level >= 1 && level <= 30, "S2 level out of range")

        // Pick the face whose +axis the viewport centre projects onto.
        // For city-sized viewports all four corners land on the same
        // face; we'll fall through `multiFace` if too many corners
        // wander to another one (cube-edge case).
        let (cx, cy, cz) = S2Grid.latLngToXYZ(
            lat: viewport.centerLat,
            lng: viewport.centerLng,
        )
        let (face, _, _) = S2Grid.xyzToFaceUV(x: cx, y: cy, z: cz)

        // Probe 5 lat/lng samples — 4 corners + centre — and keep the
        // smallest (s, t) AABB of those that land on the centre's
        // face. The centre always lands on the centre face by
        // construction, so a single-face viewport always gets all 5.
        let probes: [(Double, Double)] = [
            (viewport.minLat, viewport.minLng),
            (viewport.minLat, viewport.maxLng),
            (viewport.maxLat, viewport.minLng),
            (viewport.maxLat, viewport.maxLng),
            (viewport.centerLat, viewport.centerLng),
        ]
        var minS = Double.infinity, maxS = -Double.infinity
        var minT = Double.infinity, maxT = -Double.infinity
        var onFace = 0
        for (lat, lng) in probes {
            let (x, y, z) = S2Grid.latLngToXYZ(lat: lat, lng: lng)
            let (probeFace, u, v) = S2Grid.xyzToFaceUV(x: x, y: y, z: z)
            if probeFace != face { continue }
            onFace += 1
            let s = S2Grid.uvToST(u)
            let t = S2Grid.uvToST(v)
            if s < minS { minS = s }
            if s > maxS { maxS = s }
            if t < minT { minT = t }
            if t > maxT { maxT = t }
        }
        // Centre alone isn't enough to bound a viewport AABB — need
        // at least one corner too.
        if onFace < 2 {
            return GridLines(
                lines: [],
                effectiveLevel: level,
                requestedLevel: level,
                suppressedReason: .multiFace,
            )
        }

        // Auto-coarsen: find the finest level ≤ `level` whose
        // scanline count stays under `scanlineCap`. At wide viewports
        // a fine requested level (e.g. L20 at a 600 km span ≈
        // 60 000² cells) is physically un-renderable, so we step the
        // level down until iSpan + jSpan + 2 fits. The renderer still
        // covers the whole viewport — just at a coarser cell size —
        // which matches the "I should always see SOME grid" UX the
        // user expects when zooming out.
        var effectiveLevel = level
        var iMin = 0, iMax = 0, jMin = 0, jMax = 0
        var iSpan = 0, jSpan = 0
        while effectiveLevel >= 1 {
            let cellsPerSide = Double(1 << effectiveLevel)
            let maxIdx = Int(cellsPerSide) - 1
            iMin = max(0, Int(floor(minS * cellsPerSide)))
            iMax = min(maxIdx, Int(ceil(maxS * cellsPerSide)))
            jMin = max(0, Int(floor(minT * cellsPerSide)))
            jMax = min(maxIdx, Int(ceil(maxT * cellsPerSide)))
            iSpan = iMax - iMin + 1
            jSpan = jMax - jMin + 1
            if iSpan + jSpan + 2 <= scanlineCap { break }
            effectiveLevel -= 1
        }
        // At L1 (4 cells per face) the absolute worst case is 10
        // scanlines — well under any reasonable cap — so the loop
        // always terminates with at least one drawable level.
        if effectiveLevel < 1 { effectiveLevel = 1 }

        // Horizontal scanlines — one per `j` integer boundary from
        // jMin to jMax+1 inclusive. Each line walks all `i` boundaries
        // so it bends with the cube-projection curvature (cells aren't
        // axis-aligned in lat/lng once you're off the equator).
        var lines: [[CLLocationCoordinate2D]] = []
        lines.reserveCapacity(iSpan + jSpan + 2)
        for j in jMin...(jMax + 1) {
            var coords: [CLLocationCoordinate2D] = []
            coords.reserveCapacity(iSpan + 1)
            for i in iMin...(iMax + 1) {
                coords.append(ijLatLng(face: face, i: i, j: j, level: effectiveLevel))
            }
            lines.append(coords)
        }
        // Vertical scanlines — one per `i` integer boundary.
        for i in iMin...(iMax + 1) {
            var coords: [CLLocationCoordinate2D] = []
            coords.reserveCapacity(jSpan + 1)
            for j in jMin...(jMax + 1) {
                coords.append(ijLatLng(face: face, i: i, j: j, level: effectiveLevel))
            }
            lines.append(coords)
        }

        return GridLines(
            lines: lines,
            effectiveLevel: effectiveLevel,
            requestedLevel: level,
            suppressedReason: nil,
        )
    }

    private static func ijLatLng(face: Int, i: Int, j: Int, level: Int) -> CLLocationCoordinate2D {
        let cellSize = 1.0 / Double(1 << level)
        let s = Double(i) * cellSize
        let t = Double(j) * cellSize
        let u = S2Grid.stToUV(s)
        let v = S2Grid.stToUV(t)
        let (x, y, z) = S2Grid.faceUVToXYZ(face: face, u: u, v: v)
        let (lat, lng) = S2Grid.xyzToLatLng(x: x, y: y, z: z)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    // MARK: - BFS cell enumeration (kept for non-render callers)

    /// BFS-enumerate every S2 cell whose AABB overlaps `viewport`
    /// at `level`. `center` should be inside `viewport` — it seeds
    /// the BFS.
    public static func cellsIn(
        viewport: ViewportBounds,
        center: CLLocationCoordinate2D,
        level: Int,
        cap: Int? = nil,
    ) -> Result {
        precondition(level >= 1 && level <= 30, "S2 level out of range")
        let effectiveCap = cap ?? capForLevel(level)

        var output: [Cell] = []
        output.reserveCapacity(effectiveCap)
        var seen = Set<String>()
        var queue: [String] = []
        var head = 0

        let seed = S2Grid.latLngToKey(
            lat: center.latitude,
            lng: center.longitude,
            level: level,
        )
        queue.append(seed)
        seen.insert(seed)

        var cappedOut = false
        while head < queue.count {
            if output.count >= effectiveCap {
                cappedOut = true
                break
            }
            let key = queue[head]
            head += 1

            let corners = S2Grid.keyToCorners(key)
            let aabb = ViewportBounds(corners: corners)
            if !viewport.intersects(aabb) {
                // Don't expand off-viewport branches — for a convex
                // rectangular viewport, every cell that overlaps it
                // is reachable from `seed` through other overlapping
                // cells, so cutting non-overlapping branches doesn't
                // miss anything and avoids the cap-bound wander.
                continue
            }

            output.append(Cell(key: key, corners: corners))

            for n in S2Grid.keyToNeighbors(key) where !seen.contains(n) {
                seen.insert(n)
                queue.append(n)
            }
        }

        return Result(cells: output, cappedOut: cappedOut)
    }
}

// MARK: - ViewportBounds

/// Axis-aligned lat/lng rectangle. Used both as the input viewport
/// (from the map's visible region) and as the per-cell bounding box
/// during the BFS.
///
/// Longitude wraparound (a viewport that spans the 180°/-180° line)
/// is not modelled — at the scales LociiGhost cares about (cities,
/// neighbourhoods) it never matters, and the S2 grid view is anyway
/// disabled by the zoom-suppression rule long before the user has
/// the whole world on screen.
public struct ViewportBounds: Sendable, Equatable {
    public let minLat: Double
    public let maxLat: Double
    public let minLng: Double
    public let maxLng: Double

    public init(minLat: Double, maxLat: Double, minLng: Double, maxLng: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLng = minLng
        self.maxLng = maxLng
    }

    /// Smallest enclosing AABB of a polygon ring.
    public init(corners: [CLLocationCoordinate2D]) {
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLng = Double.infinity, maxLng = -Double.infinity
        for c in corners {
            if c.latitude  < minLat { minLat = c.latitude  }
            if c.latitude  > maxLat { maxLat = c.latitude  }
            if c.longitude < minLng { minLng = c.longitude }
            if c.longitude > maxLng { maxLng = c.longitude }
        }
        self.init(minLat: minLat, maxLat: maxLat, minLng: minLng, maxLng: maxLng)
    }

    public func intersects(_ other: ViewportBounds) -> Bool {
        return !(other.maxLat < minLat ||
                 other.minLat > maxLat ||
                 other.maxLng < minLng ||
                 other.minLng > maxLng)
    }

    public var centerLat: Double { (minLat + maxLat) * 0.5 }
    public var centerLng: Double { (minLng + maxLng) * 0.5 }
}
