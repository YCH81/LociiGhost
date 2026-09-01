import XCTest
@testable import LociiGhostCore

/// The point of `DwellRange` is that the draw and the estimate can't
/// drift apart, so that's what most of these pin down.
final class DwellRangeTests: XCTestCase {

    /// A generator with a scripted sequence, so a draw can be asserted
    /// exactly instead of statistically.
    private struct ScriptedGenerator: RandomNumberGenerator {
        var values: [UInt64]
        var index = 0
        mutating func next() -> UInt64 {
            defer { index += 1 }
            return values[index % values.count]
        }
    }

    // MARK: - Normalising

    func testReversedBoundsAreSwappedRatherThanRejected() {
        let r = DwellRange(min: 20, max: 5)
        XCTAssertEqual(r.minSeconds, 5)
        XCTAssertEqual(r.maxSeconds, 20)
    }

    func testZeroAndNegativeClampToOneSecond() {
        XCTAssertEqual(DwellRange(min: 0, max: 0).minSeconds, 1)
        XCTAssertEqual(DwellRange(min: -30, max: 8).minSeconds, 1)
        XCTAssertEqual(DwellRange(min: -30, max: 8).maxSeconds, 8)
        XCTAssertEqual(DwellRange(min: -5, max: -2).maxSeconds, 1)
    }

    func testFixedRangeIsRecognised() {
        XCTAssertTrue(DwellRange(fixed: 7).isFixed)
        XCTAssertFalse(DwellRange(min: 5, max: 20).isFixed)
    }

    // MARK: - Drawing

    func testEveryDrawLandsInsideTheRange() {
        let r = DwellRange(min: 5, max: 20)
        var g = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let v = r.pick(using: &g)
            XCTAssertGreaterThanOrEqual(v, 5)
            XCTAssertLessThanOrEqual(v, 20)
        }
    }

    func testAFixedRangeAlwaysYieldsItsValueAndNeverTouchesTheGenerator() {
        // An empty script: any call to next() would trap on the
        // modulo of an empty array, so this also proves the fixed
        // path short-circuits before drawing.
        var g = ScriptedGenerator(values: [])
        let r = DwellRange(fixed: 9)
        XCTAssertEqual(r.pick(using: &g), 9)
        XCTAssertEqual(r.pick(using: &g), 9)
    }

    func testAWideRangeActuallyVaries() {
        // The whole feature is "stop being predictable", so a draw
        // that returned the same number every time would pass every
        // other test here while defeating the point.
        let r = DwellRange(min: 5, max: 20)
        var g = SystemRandomNumberGenerator()
        let seen = Set((0..<400).map { _ in r.pick(using: &g) })
        XCTAssertGreaterThan(seen.count, 5,
                             "expected a spread of dwell values, got \(seen.sorted())")
    }

    // MARK: - Estimating

    func testExpectedSecondsIsTheMidpoint() {
        XCTAssertEqual(DwellRange(min: 5, max: 20).expectedSeconds, 12.5, accuracy: 0.0001)
        XCTAssertEqual(DwellRange(fixed: 8).expectedSeconds, 8, accuracy: 0.0001)
    }

    func testExpectedSecondsKeepsItsHalfSecond() {
        // Rounding here would bias every stop by up to half a second.
        // Over a 40-stop trip that's 20 seconds of ETA error, which is
        // exactly the kind of drift the ETA is supposed to not have.
        let r = DwellRange(min: 5, max: 20)
        XCTAssertEqual(r.expectedTotal(stops: 40), 500, accuracy: 0.0001)
        XCTAssertNotEqual(r.expectedTotal(stops: 40), 480)
    }

    func testExpectedTotalIsZeroForNoStops() {
        XCTAssertEqual(DwellRange(min: 5, max: 20).expectedTotal(stops: 0), 0)
        XCTAssertEqual(DwellRange(min: 5, max: 20).expectedTotal(stops: -3), 0)
    }

    /// The estimate has to track the draw. If someone changes `pick`
    /// to, say, bias toward the low end, this is what notices.
    func testTheEstimateMatchesTheMeanOfManyDraws() {
        let r = DwellRange(min: 5, max: 20)
        var g = SystemRandomNumberGenerator()
        let n = 20_000
        let total = (0..<n).reduce(0) { acc, _ in acc + r.pick(using: &g) }
        let observed = Double(total) / Double(n)
        XCTAssertEqual(observed, r.expectedSeconds, accuracy: 0.25,
                       "pick() and expectedSeconds have drifted apart")
    }

    // MARK: - Round trip

    func testCodableRoundTrip() throws {
        let r = DwellRange(min: 5, max: 20)
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(DwellRange.self, from: data), r)
    }
}
