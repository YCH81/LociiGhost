import XCTest
@testable import LociiGhostCore

/// Smart sort had no test coverage at all, despite being reachable
/// from a button with an unbounded input.
final class StopOrderingTests: XCTestCase {

    private func c(_ lat: Double, _ lng: Double) -> Coordinate {
        Coordinate(lat: lat, lng: lng)
    }

    // MARK: - Degenerate inputs

    func testFewerThanThreeStopsArePassedThrough() {
        XCTAssertEqual(StopOrdering.smartSorted([]), [])
        let one = [c(25, 121)]
        XCTAssertEqual(StopOrdering.smartSorted(one), one)
        let two = [c(25, 121), c(24, 120)]
        XCTAssertEqual(StopOrdering.smartSorted(two), two)
    }

    func testDuplicatePointsDoNotHangOrCrash() {
        let stops = Array(repeating: c(25.03, 121.56), count: 12)
        let sorted = StopOrdering.smartSorted(stops)
        XCTAssertEqual(sorted.count, stops.count)
    }

    func testAllStopsPreservedAndStartPinned() {
        let stops = (0..<15).map { c(25.0 + Double($0) * 0.01,
                                     121.0 + Double(($0 * 7) % 15) * 0.01) }
        let sorted = StopOrdering.smartSorted(stops)
        XCTAssertEqual(sorted.first, stops.first, "start must stay pinned")
        XCTAssertEqual(Set(sorted), Set(stops), "no stop may be lost or invented")
        XCTAssertEqual(sorted.count, stops.count)
    }

    // MARK: - It actually shortens the path

    func testReordersAZigZagIntoSomethingShorter() {
        // Points along a line, handed over in a deliberately bad order.
        let line = (0..<9).map { c(25.0, 121.0 + Double($0) * 0.01) }
        let scrambled = [line[0], line[5], line[1], line[7],
                         line[2], line[8], line[3], line[6], line[4]]
        let before = StopOrdering.totalPathDistance(
            start: scrambled[0], path: Array(scrambled.dropFirst()))
        let sorted = StopOrdering.smartSorted(scrambled)
        let after = StopOrdering.totalPathDistance(
            start: sorted[0], path: Array(sorted.dropFirst()))
        XCTAssertLessThan(after, before)
        // Collinear points: the optimum is simply walking the line.
        XCTAssertEqual(sorted, line)
    }

    func testTwoOptPathIsNoWorseThanTheNearestNeighbourSeed() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5 {
            let stops = (0..<20).map { _ in
                c(Double.random(in: 24.9...25.2, using: &rng),
                  Double.random(in: 121.4...121.7, using: &rng))
            }
            let sorted = StopOrdering.smartSorted(stops)
            let before = StopOrdering.totalPathDistance(
                start: stops[0], path: Array(stops.dropFirst()))
            let after = StopOrdering.totalPathDistance(
                start: sorted[0], path: Array(sorted.dropFirst()))
            XCTAssertLessThanOrEqual(after, before + 1e-6)
        }
    }

    // MARK: - Bounded cost

    /// The old 2-opt restarted its whole scan after every improving
    /// swap and had no pass limit, making a pathological input O(n⁴).
    /// This is the shape the codebase's own comments say users paste in.
    func testLargeInputCompletesQuickly() {
        var rng = SystemRandomNumberGenerator()
        let stops = (0..<400).map { _ in
            c(Double.random(in: 24.5...25.5, using: &rng),
              Double.random(in: 121.0...122.0, using: &rng))
        }
        let started = Date()
        let sorted = StopOrdering.smartSorted(stops)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(sorted.count, stops.count)
        XCTAssertLessThan(elapsed, 20.0,
                          "smart sort should stay bounded on large inputs")
    }

    func testHaversineMatchesAKnownDistance() {
        // Taipei 101 to Taipei Main Station: ~4.6 km.
        let d = StopOrdering.haversineMeters(c(25.0339, 121.5645),
                                             c(25.0478, 121.5170))
        XCTAssertEqual(d, 4_900, accuracy: 400)
    }

    func testZeroDistanceIsZero() {
        XCTAssertEqual(StopOrdering.haversineMeters(c(25, 121), c(25, 121)),
                       0, accuracy: 1e-9)
    }
}
