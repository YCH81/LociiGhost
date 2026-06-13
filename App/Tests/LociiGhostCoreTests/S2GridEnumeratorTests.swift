import XCTest
import CoreLocation
@testable import LociiGhostCore

final class S2GridEnumeratorTests: XCTestCase {

    /// Viewport so small that only the seed cell intersects it.
    func testSingleCellWhenViewportIsSubCellSize() {
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        // L17 ≈ 76 m × 76 m at this latitude. A 10 m viewport sits
        // wholly inside the centre cell.
        let halfMeters = 5.0
        let viewport = boundsCentered(at: centre, halfMeters: halfMeters)
        let result = S2GridEnumerator.cellsIn(
            viewport: viewport,
            center: centre,
            level: 17,
        )
        XCTAssertEqual(result.cells.count, 1)
        XCTAssertFalse(result.cappedOut)
    }

    /// Modest viewport — should produce a handful of cells around the
    /// centre but well below the cap.
    func testReasonableViewport_producesSeveralButNotCapped() {
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        // ~500 m radius → 1 km × 1 km viewport. L17 ≈ 76 m so we
        // expect ~13 × 13 ≈ 170 cells, give or take edge alignment.
        let viewport = boundsCentered(at: centre, halfMeters: 500)
        let result = S2GridEnumerator.cellsIn(
            viewport: viewport,
            center: centre,
            level: 17,
        )
        XCTAssertGreaterThan(result.cells.count, 80,
                             "expected a few hundred cells, got \(result.cells.count)")
        XCTAssertLessThan(result.cells.count, 400)
        XCTAssertFalse(result.cappedOut)
    }

    /// Result cells should all be uniquely keyed and have valid corners.
    func testResultCellsAreUniqueAndValid() {
        let centre = CLLocationCoordinate2D(latitude: 35.6586, longitude: 139.7454)
        let viewport = boundsCentered(at: centre, halfMeters: 300)
        let result = S2GridEnumerator.cellsIn(
            viewport: viewport,
            center: centre,
            level: 17,
        )
        let keys = result.cells.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate keys in result")
        for cell in result.cells {
            XCTAssertEqual(cell.corners.count, 4)
        }
    }

    /// Every returned cell's AABB must actually intersect the viewport.
    func testEveryReturnedCellIntersectsViewport() {
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let viewport = boundsCentered(at: centre, halfMeters: 500)
        let result = S2GridEnumerator.cellsIn(
            viewport: viewport,
            center: centre,
            level: 17,
        )
        for cell in result.cells {
            let cellAABB = ViewportBounds(corners: cell.corners)
            XCTAssertTrue(viewport.intersects(cellAABB),
                          "cell \(cell.key) reported but doesn't intersect viewport")
        }
    }

    /// Cap kicks in for huge viewports at high levels.
    func testCapAtSmallLevel_largeViewport() {
        let centre = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        // ~5 km × 5 km viewport at L20 (~9.5 m cells) → > 250 000
        // cells if unbounded; we'd hit the 10 k cap fast.
        let viewport = boundsCentered(at: centre, halfMeters: 2_500)
        let result = S2GridEnumerator.cellsIn(
            viewport: viewport,
            center: centre,
            level: 20,
        )
        XCTAssertTrue(result.cappedOut)
        XCTAssertLessThanOrEqual(result.cells.count,
                                 S2GridEnumerator.capForLevel(20))
    }

    /// Per-level cap monotonicity.
    func testCapMonotonic() {
        for level in 13..<20 {
            XCTAssertLessThanOrEqual(
                S2GridEnumerator.capForLevel(level),
                S2GridEnumerator.capForLevel(level + 1),
                "cap at L\(level) should be ≤ cap at L\(level + 1)",
            )
        }
    }

    /// Custom cap arg overrides the default.
    func testCustomCapTakesPrecedence() {
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let viewport = boundsCentered(at: centre, halfMeters: 500)
        let result = S2GridEnumerator.cellsIn(
            viewport: viewport,
            center: centre,
            level: 17,
            cap: 10,
        )
        XCTAssertEqual(result.cells.count, 10)
        XCTAssertTrue(result.cappedOut)
    }

    // MARK: - ViewportBounds helpers

    func testViewportBoundsIntersects_overlap() {
        let a = ViewportBounds(minLat: 0, maxLat: 1, minLng: 0, maxLng: 1)
        let b = ViewportBounds(minLat: 0.5, maxLat: 1.5, minLng: 0.5, maxLng: 1.5)
        XCTAssertTrue(a.intersects(b))
        XCTAssertTrue(b.intersects(a))
    }

    func testViewportBoundsIntersects_disjoint() {
        let a = ViewportBounds(minLat: 0, maxLat: 1, minLng: 0, maxLng: 1)
        let far = ViewportBounds(minLat: 10, maxLat: 11, minLng: 10, maxLng: 11)
        XCTAssertFalse(a.intersects(far))
    }

    func testViewportBoundsIntersects_touching() {
        // Edge touch counts as intersection — `!(<)` includes equality.
        let a = ViewportBounds(minLat: 0, maxLat: 1, minLng: 0, maxLng: 1)
        let b = ViewportBounds(minLat: 1, maxLat: 2, minLng: 0, maxLng: 1)
        XCTAssertTrue(a.intersects(b))
    }

    func testViewportBoundsFromCorners() {
        let corners = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 1, longitude: 0),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
        ]
        let b = ViewportBounds(corners: corners)
        XCTAssertEqual(b.minLat, 0)
        XCTAssertEqual(b.maxLat, 1)
        XCTAssertEqual(b.minLng, 0)
        XCTAssertEqual(b.maxLng, 1)
    }

    // MARK: - gridLines (scanline renderer source)

    func testGridLinesProducesAtLeastOneScanlineEachAxis() {
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let viewport = boundsCentered(at: centre, halfMeters: 200)
        let result = S2GridEnumerator.gridLines(viewport: viewport, level: 17)
        XCTAssertGreaterThanOrEqual(result.lines.count, 2,
                                    "need at least one horizontal + one vertical scanline")
        XCTAssertEqual(result.effectiveLevel, 17)
        XCTAssertEqual(result.requestedLevel, 17)
        XCTAssertNil(result.suppressedReason)
    }

    func testGridLinesEachLineHasMultipleVertices() {
        // Scanlines walk every i (or j) boundary so they curve with
        // the projection. A 1 km viewport at L17 should give each
        // line ~14 vertices.
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let viewport = boundsCentered(at: centre, halfMeters: 500)
        let result = S2GridEnumerator.gridLines(viewport: viewport, level: 17)
        for line in result.lines {
            XCTAssertGreaterThanOrEqual(line.count, 2)
        }
    }

    /// At a typical 1 km city viewport L17 should fit comfortably —
    /// no auto-coarsen, scanline count ~2× iSpan well under the cap.
    func testGridLines_doesNotCoarsen_atNarrowViewport() {
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let viewport = boundsCentered(at: centre, halfMeters: 500)
        let result = S2GridEnumerator.gridLines(viewport: viewport, level: 17)
        XCTAssertEqual(result.effectiveLevel, result.requestedLevel)
        XCTAssertFalse(result.wasCoarsened)
    }

    /// At Taiwan scale (~400 km half-width) L17 would need ~10 k
    /// scanlines; the auto-coarsen path should drop to a level that
    /// fits the default cap (300).
    func testGridLines_coarsensRequestedLevel_atWideViewport() {
        let centre = CLLocationCoordinate2D(latitude: 24.0, longitude: 121.0)
        let viewport = boundsCentered(at: centre, halfMeters: 200_000) // 400 km tall
        let result = S2GridEnumerator.gridLines(viewport: viewport, level: 17, scanlineCap: 300)
        XCTAssertTrue(result.wasCoarsened, "L17 at 400 km should coarsen")
        XCTAssertLessThan(result.effectiveLevel, 17)
        XCTAssertGreaterThanOrEqual(result.effectiveLevel, 1)
        XCTAssertNil(result.suppressedReason, "should still draw, just at a coarser level")
        XCTAssertFalse(result.lines.isEmpty)
    }

    /// Wider scanline budget → grid stays at the requested level for
    /// the same viewport. Confirms the cap is the only constraint.
    func testGridLines_higherCapPreservesRequestedLevel() {
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let viewport = boundsCentered(at: centre, halfMeters: 25_000) // 50 km tall
        let tightCap = S2GridEnumerator.gridLines(viewport: viewport, level: 17, scanlineCap: 300)
        let looseCap = S2GridEnumerator.gridLines(viewport: viewport, level: 17, scanlineCap: 3_000)
        XCTAssertTrue(tightCap.wasCoarsened)
        XCTAssertFalse(looseCap.wasCoarsened)
        XCTAssertEqual(looseCap.effectiveLevel, 17)
    }

    func testGridLines_lineCountBelowCap() {
        let centre = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let viewport = boundsCentered(at: centre, halfMeters: 5_000)
        let cap = 100
        let result = S2GridEnumerator.gridLines(viewport: viewport, level: 17, scanlineCap: cap)
        XCTAssertLessThanOrEqual(result.lines.count, cap + 2)
    }

    /// Auto-coarsen always succeeds — even the worst-case wide
    /// viewport drops to L1 (4 cells per face, ≈ 10 scanlines)
    /// rather than returning an empty result.
    func testGridLines_alwaysProducesLines_evenAtExtremeViewport() {
        let centre = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        // 200 km half-width → 400 km tall; cap of 6 (extreme)
        let viewport = boundsCentered(at: centre, halfMeters: 200_000)
        let result = S2GridEnumerator.gridLines(viewport: viewport, level: 20, scanlineCap: 10)
        XCTAssertFalse(result.lines.isEmpty)
        XCTAssertGreaterThanOrEqual(result.effectiveLevel, 1)
    }

    // MARK: - helpers

    /// Build an AABB around `centre` whose half-side is `halfMeters` on
    /// the ground. Uses the cheap approximation 1° lat ≈ 111 km — fine
    /// for the small viewports we test.
    private func boundsCentered(
        at centre: CLLocationCoordinate2D,
        halfMeters: Double,
    ) -> ViewportBounds {
        let dLat = halfMeters / 111_000.0
        let dLng = halfMeters / (111_000.0 * cos(centre.latitude * .pi / 180))
        return ViewportBounds(
            minLat: centre.latitude  - dLat,
            maxLat: centre.latitude  + dLat,
            minLng: centre.longitude - dLng,
            maxLng: centre.longitude + dLng,
        )
    }
}
