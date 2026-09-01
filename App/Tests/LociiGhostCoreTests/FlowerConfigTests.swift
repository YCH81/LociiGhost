import XCTest
@testable import LociiGhostCore

final class FlowerConfigTests: XCTestCase {

    func testOutOfRangeValuesAreClamped() {
        let wild = FlowerConfig(radiusM: 99_999, segments: 200, laps: 900,
                                rounds: 0, speedMps: 0)
        XCTAssertEqual(wild.radiusM, 2_000)
        XCTAssertEqual(wild.segments, 20)
        XCTAssertEqual(wild.laps, 50)
        XCTAssertEqual(wild.rounds, 1)
        XCTAssertGreaterThan(wild.speedMps, 0)
        XCTAssertEqual(FlowerConfig(segments: 1).segments, 3)
    }

    /// The panel binds straight to these properties, so most writes
    /// never go through `init`.
    func testMutatingAPropertyClampsToo() {
        var config = FlowerConfig.standard
        config.segments = 200
        config.laps = 0.1
        config.radiusM = -20
        config.rounds = 0
        config.dwellSeconds = -3
        XCTAssertEqual(config.segments, 20)
        XCTAssertEqual(config.laps, 0.5)
        XCTAssertEqual(config.radiusM, 1)
        XCTAssertEqual(config.rounds, 1)
        XCTAssertEqual(config.dwellSeconds, 0)
    }

    func testNegativeWaitsBecomeZero() {
        let config = FlowerConfig(waitBeforeSeconds: -5, waitAfterSeconds: -1,
                                  dwellSeconds: -9)
        XCTAssertEqual(config.waitBeforeSeconds, 0)
        XCTAssertEqual(config.waitAfterSeconds, 0)
        XCTAssertEqual(config.dwellSeconds, 0)
    }

    func testLapsSnapToHalfSteps() {
        XCTAssertEqual(FlowerConfig.snapLaps(1.2), 1.0)
        XCTAssertEqual(FlowerConfig.snapLaps(1.3), 1.5)
        XCTAssertEqual(FlowerConfig.snapLaps(0.1), 0.5)
    }

    /// The daemon spells this as `floor(x + 0.5)` because Python's
    /// `round` sends halves to even. Swift's `rounded()` goes away
    /// from zero, so both give the same answer — this pins the pair
    /// that has to agree.
    func testHalfLapsRoundUpTheSameWayTheDaemonDoes() {
        XCTAssertEqual(FlowerConfig(segments: 5, laps: 0.5).verticesPerPoint, 3)
        XCTAssertEqual(FlowerConfig(segments: 7, laps: 0.5).verticesPerPoint, 4)
        XCTAssertEqual(FlowerConfig(segments: 8, laps: 1).verticesPerPoint, 8)
    }

    func testNonFiniteInputDoesNotProduceANonFiniteSetting() {
        let config = FlowerConfig(radiusM: .nan, laps: .infinity, speedMps: .nan)
        XCTAssertTrue(config.radiusM.isFinite)
        XCTAssertTrue(config.laps.isFinite)
        XCTAssertTrue(config.speedMps.isFinite)
    }

    /// The wire field names are the daemon's vocabulary. A rename here
    /// is a silently ignored setting there — `with_defaults` skips keys
    /// it doesn't know so an older daemon doesn't reject a newer app.
    func testTheParameterNamesAreTheDaemonsSpelling() {
        let keys = Set(FlowerConfig.standard.rpcParameters.keys)
        XCTAssertEqual(keys, [
            "radius_m", "segments", "laps", "rounds",
            "wait_before_s", "wait_after_s", "dwell_s", "speed_mps",
        ])
    }

    /// A blob written by a newer build, or edited by hand, must not
    /// come back holding values the UI's own steppers can't show.
    func testDecodingClampsToo() throws {
        let json = """
        {"radiusM": 99999, "segments": 200, "laps": 0.1, "rounds": 0,
         "waitBeforeSeconds": -3, "waitAfterSeconds": 0, "dwellSeconds": 0,
         "speedMps": 1.4, "teleportBetween": false}
        """
        let config = try JSONDecoder().decode(FlowerConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.segments, 20)
        XCTAssertEqual(config.radiusM, 2_000)
        XCTAssertEqual(config.laps, 0.5)
        XCTAssertEqual(config.rounds, 1)
        XCTAssertEqual(config.waitBeforeSeconds, 0)
    }

    func testItSurvivesACodableRoundTrip() throws {
        let config = FlowerConfig(radiusM: 75, segments: 12, laps: 2.5, rounds: 4,
                                  waitBeforeSeconds: 3, dwellSeconds: 2,
                                  teleportBetween: true)
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(FlowerConfig.self, from: data), config)
    }
}
