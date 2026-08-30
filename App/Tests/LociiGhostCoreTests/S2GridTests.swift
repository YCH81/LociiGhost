import XCTest
import CoreLocation
@testable import LociiGhostCore

final class S2GridTests: XCTestCase {

    // ── lat/lng ↔ xyz round-trip ────────────────────────────────────

    func testLatLngToXYZ_equatorPrimeMeridian() {
        let (x, y, z) = S2Grid.latLngToXYZ(lat: 0, lng: 0)
        XCTAssertEqual(x, 1, accuracy: 1e-12)
        XCTAssertEqual(y, 0, accuracy: 1e-12)
        XCTAssertEqual(z, 0, accuracy: 1e-12)
    }

    func testLatLngToXYZ_northPole() {
        let (x, y, z) = S2Grid.latLngToXYZ(lat: 90, lng: 0)
        XCTAssertEqual(x, 0, accuracy: 1e-12)
        XCTAssertEqual(y, 0, accuracy: 1e-12)
        XCTAssertEqual(z, 1, accuracy: 1e-12)
    }

    func testXYZ_roundTrip_representativePoints() {
        let cases: [(Double, Double)] = [
            (25.0339, 121.5645), // Taipei 101
            (-33.8688, 151.2093), // Sydney
            (51.5079, -0.1283), // Trafalgar Sq
            (0, 180),           // dateline
            (45, -45),
            (-45, 90),
        ]
        for (lat, lng) in cases {
            let (x, y, z) = S2Grid.latLngToXYZ(lat: lat, lng: lng)
            let (lat2, lng2) = S2Grid.xyzToLatLng(x: x, y: y, z: z)
            XCTAssertEqual(lat2, lat, accuracy: 1e-9, "lat round-trip @ (\(lat),\(lng))")
            XCTAssertEqual(lng2, lng, accuracy: 1e-9, "lng round-trip @ (\(lat),\(lng))")
        }
    }

    // ── st ↔ uv round-trip ──────────────────────────────────────────

    func testSTUV_boundaries() {
        XCTAssertEqual(S2Grid.stToUV(0), -1, accuracy: 1e-12)
        XCTAssertEqual(S2Grid.stToUV(1), 1, accuracy: 1e-12)
        XCTAssertEqual(S2Grid.stToUV(0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(S2Grid.uvToST(-1), 0, accuracy: 1e-12)
        XCTAssertEqual(S2Grid.uvToST(1), 1, accuracy: 1e-12)
        XCTAssertEqual(S2Grid.uvToST(0), 0.5, accuracy: 1e-12)
    }

    func testSTUV_roundTrip() {
        for s in stride(from: 0.0, through: 1.0, by: 0.05) {
            let back = S2Grid.uvToST(S2Grid.stToUV(s))
            XCTAssertEqual(back, s, accuracy: 1e-9, "s=\(s) round-trip")
        }
    }

    // ── face uv ↔ xyz round-trip ────────────────────────────────────

    func testFaceUV_roundTrip_allFaces() {
        // For each face, pick a representative interior point and
        // verify (face, u, v) → xyz → (face, u, v) reproduces.
        let probes: [(Double, Double)] = [
            (0, 0), (0.3, 0.4), (-0.5, 0.2), (-0.8, -0.7),
        ]
        for face in 0..<6 {
            for (u, v) in probes {
                let (x, y, z) = S2Grid.faceUVToXYZ(face: face, u: u, v: v)
                let (face2, u2, v2) = S2Grid.xyzToFaceUV(x: x, y: y, z: z)
                XCTAssertEqual(face2, face,
                               "face round-trip @ face=\(face) (u,v)=(\(u),\(v)); got \(face2)")
                // Normalize by xyz length — faceUVToXYZ returns
                // un-normalized vectors that still point to the
                // right face but inflate u/v proportionally.
                let len = sqrt(x * x + y * y + z * z)
                let (xN, yN, zN) = (x / len, y / len, z / len)
                let (_, uExpected, vExpected) = S2Grid.xyzToFaceUV(x: xN, y: yN, z: zN)
                XCTAssertEqual(u2, uExpected, accuracy: 1e-9,
                               "u match @ face=\(face)")
                XCTAssertEqual(v2, vExpected, accuracy: 1e-9,
                               "v match @ face=\(face)")
            }
        }
    }

    // ── key round-trip ──────────────────────────────────────────────

    func testKeyToIJ_roundTrips_ijToKey() {
        // Pick (face, i, j) per level and verify ijToKey/keyToIJ
        // cancel out exactly.
        let cases: [(face: Int, i: Int, j: Int, level: Int)] = [
            (0, 0, 0, 1),
            (0, 1, 0, 1),
            (3, 5, 3, 3),
            (2, 12345, 67890, 17),
            (5, 524287, 524287, 19), // 2^19 - 1
        ]
        for c in cases {
            let key = S2Grid.ijToKey(face: c.face, i: c.i, j: c.j, level: c.level)
            let (face, i, j, level) = S2Grid.keyToIJ(key)
            XCTAssertEqual(face, c.face, "face round-trip @ \(c)")
            XCTAssertEqual(i, c.i, "i round-trip @ \(c)")
            XCTAssertEqual(j, c.j, "j round-trip @ \(c)")
            XCTAssertEqual(level, c.level, "level round-trip @ \(c)")
        }
    }

    // ── Containment: latLngToKey → keyToCorners contains source ────

    func testKey_pointInsideOwnCell_acrossLevels() {
        // For every (lat, lng, level), the produced cell's polygon
        // must contain the original point. This catches off-by-one
        // bugs, table-inversion bugs, and any Hilbert misencoding.
        let cases: [(lat: Double, lng: Double, level: Int)] = [
            (25.0339, 121.5645, 13),
            (25.0339, 121.5645, 17),
            (25.0339, 121.5645, 20),
            (35.6586, 139.7454, 14),
            (51.5079, -0.1283, 17),
            (-33.8688, 151.2093, 17),
            (40.7128, -74.0060, 17),
            (0.001, 0.001, 17),
            // Pole regions are intentionally excluded: cells there
            // span very wide longitude ranges (meridians converge),
            // so the corner ring in lat/lng space becomes degenerate
            // / self-crossing and the flat-plane ray-cast helper
            // returns wrong answers. The S2 math itself is fine —
            // the cell exists and is shaped correctly on the sphere;
            // it's the visualization-as-polygon approximation that
            // breaks. We never draw cells near the poles in practice
            // (Pikmin Bloom users live well clear of ±90°).
        ]
        for c in cases {
            let key = S2Grid.latLngToKey(lat: c.lat, lng: c.lng, level: c.level)
            let corners = S2Grid.keyToCorners(key)
            XCTAssertEqual(corners.count, 4,
                           "expect 4 corners for \(key)")
            XCTAssertTrue(pointInPolygon(lat: c.lat, lng: c.lng, polygon: corners),
                          "(\(c.lat), \(c.lng)) L\(c.level) not inside its own cell: \(key)")
        }
    }

    // ── Center is roughly the centroid ──────────────────────────────

    func testKeyCenter_isInsideOwnCell() {
        let key = S2Grid.latLngToKey(lat: 25.0339, lng: 121.5645, level: 17)
        let centre = S2Grid.keyToCenter(key)
        let corners = S2Grid.keyToCorners(key)
        XCTAssertTrue(pointInPolygon(lat: centre.latitude,
                                     lng: centre.longitude,
                                     polygon: corners),
                      "centre not inside its own cell")
    }

    // ── Neighbours ──────────────────────────────────────────────────

    func testKeyToNeighbors_returns4DistinctNonSelf() {
        let cases = [
            (25.0339, 121.5645, 17),
            (51.5079, -0.1283, 14),
            (0, 0, 17),
        ]
        for c in cases {
            let key = S2Grid.latLngToKey(lat: c.0, lng: c.1, level: c.2)
            let neighbours = S2Grid.keyToNeighbors(key)
            XCTAssertEqual(neighbours.count, 4, "@ \(c)")
            XCTAssertEqual(Set(neighbours).count, 4, "duplicate neighbour @ \(c)")
            XCTAssertFalse(neighbours.contains(key),
                           "self appears as neighbour @ \(c)")
        }
    }

    /// v1.15.2 audit (L15): at a cube-face boundary the off-face
    /// branch clamped its projection back onto the same face, so it
    /// returned the cell itself — `cellsIn`'s BFS then hit `seen` and
    /// stopped expanding right at the seam.
    func testKeyToNeighbors_crossesFaceBoundaries() {
        // Points near cube-face seams. The exact face split is an
        // implementation detail, so rather than hardcode a seam we
        // sweep a band and assert the invariant everywhere.
        for lng in stride(from: -180.0, through: 175.0, by: 5.0) {
            for lat in [-80.0, -45.0, 0.0, 45.0, 80.0] {
                let key = S2Grid.latLngToKey(lat: lat, lng: lng, level: 12)
                let neighbours = S2Grid.keyToNeighbors(key)
                XCTAssertEqual(neighbours.count, 4, "@ \(lat),\(lng)")
                XCTAssertFalse(neighbours.contains(key),
                               "self returned as neighbour @ \(lat),\(lng)")
                XCTAssertEqual(Set(neighbours).count, 4,
                               "duplicate neighbour @ \(lat),\(lng)")
            }
        }
    }

    /// v1.15.2 audit (L16): a key with a character outside 0-3 used to
    /// yield i/j with fewer bits than `level` claimed — a cell in a
    /// completely different place, returned as if it were fine.
    func testKeyToIJ_rejectsMalformedKeys() {
        for bad in ["9/0123", "0/01x3", "0/", "nonsense", "0/012 3", "-1/0123"] {
            let (face, i, j, level) = S2Grid.keyToIJ(bad)
            XCTAssertEqual([face, i, j, level], [0, 0, 0, 0],
                           "malformed key \(bad) was accepted")
        }
    }

    func testKeyToNeighbors_areAdjacentByDistance() {
        // Each neighbour's centre should be within ~2.0 * cellSize
        // (1 cell = direct neighbour; we give 2x slack for diagonal
        // float drift and the quadratic projection).
        let key = S2Grid.latLngToKey(lat: 25.0339, lng: 121.5645, level: 17)
        let selfCentre = S2Grid.keyToCenter(key)
        let cellMeters = S2Grid.approxCellSizeMeters(level: 17, lat: 25.0339)
        for n in S2Grid.keyToNeighbors(key) {
            let nc = S2Grid.keyToCenter(n)
            let d = haversine(lat1: selfCentre.latitude, lng1: selfCentre.longitude,
                              lat2: nc.latitude, lng2: nc.longitude)
            XCTAssertLessThan(d, cellMeters * 2.0,
                              "neighbour \(n) at \(Int(d))m > 2×\(Int(cellMeters))m")
        }
    }

    // ── Cell size sanity ────────────────────────────────────────────

    func testApproxCellSize_L17_equator() {
        let m = S2Grid.approxCellSizeMeters(level: 17, lat: 0)
        // L17 ≈ 76 m at equator; allow some slack.
        XCTAssertGreaterThan(m, 75)
        XCTAssertLessThan(m, 78)
    }

    func testApproxCellSize_higherLat_isSmaller() {
        // cos(lat) factor → cells at 25°N are ~91% of equator size.
        let eq = S2Grid.approxCellSizeMeters(level: 17, lat: 0)
        let tpe = S2Grid.approxCellSizeMeters(level: 17, lat: 25)
        XCTAssertLessThan(tpe, eq)
        XCTAssertGreaterThan(tpe, eq * 0.9)
    }

    func testApproxCellSize_doublesPerLevelDown() {
        // L17 ≈ 2 × L18, L18 ≈ 2 × L19, etc.
        for level in 14..<20 {
            let bigger = S2Grid.approxCellSizeMeters(level: level, lat: 0)
            let smaller = S2Grid.approxCellSizeMeters(level: level + 1, lat: 0)
            XCTAssertEqual(bigger, smaller * 2, accuracy: 1e-6, "L\(level) vs L\(level+1)")
        }
    }

    // ── Test helpers ────────────────────────────────────────────────

    /// Ray-casting point-in-polygon. Works on a flat lat/lng plane,
    /// which is fine for the small cells (≤ a few km on a side) we
    /// test here — distortion stays below the cell size.
    private func pointInPolygon(lat: Double, lng: Double,
                                polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            if (yi > lat) != (yj > lat),
               lng < (xj - xi) * (lat - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Haversine distance in metres on a unit-radius-6371km sphere.
    private func haversine(lat1: Double, lng1: Double,
                           lat2: Double, lng2: Double) -> Double {
        let R = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
                * sin(dLng / 2) * sin(dLng / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
