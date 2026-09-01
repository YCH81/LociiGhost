import XCTest
@testable import LociiGhostCore

final class CooldownConfigTests: XCTestCase {

    /// A gate that silently delays teleports has to be something the
    /// user switched on knowingly, or the app just looks broken.
    func testItIsOffByDefault() {
        XCTAssertFalse(CooldownConfig.standard.enabled)
    }

    func testNegativeAndNonFiniteValuesNeverReachTheDaemon() {
        var config = CooldownConfig(enabled: true, maxSpeedKmh: -30,
                                    minimumGapSeconds: .nan)
        XCTAssertEqual(config.maxSpeedKmh, 0)
        XCTAssertEqual(config.minimumGapSeconds, 0)
        config.minimumGapSeconds = -8
        XCTAssertEqual(config.minimumGapSeconds, 0)
    }

    /// `from_params` on the daemon reads exactly these keys and ignores
    /// anything else, so a rename here is a setting that silently stops
    /// arriving.
    func testTheParameterNamesAreTheDaemonsSpelling() {
        let params = CooldownConfig(enabled: true, maxSpeedKmh: 80,
                                    minimumGapSeconds: 3).rpcParameters
        XCTAssertEqual(Set(params.keys), ["enabled", "max_speed_kmh", "minimum_gap_s"])
        XCTAssertEqual(params["max_speed_kmh"]?.value as? Double, 80)
        XCTAssertEqual(params["minimum_gap_s"]?.value as? Double, 3)
        XCTAssertEqual(params["enabled"]?.value as? Bool, true)
    }

    func testItSurvivesACodableRoundTrip() throws {
        let config = CooldownConfig(enabled: true, maxSpeedKmh: 45,
                                    minimumGapSeconds: 12)
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(CooldownConfig.self, from: data), config)
    }
}
