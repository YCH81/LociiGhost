import XCTest
@testable import LociiGhostCore

/// The lap decision has been got wrong twice in shipped builds, both
/// times invisibly. These pin the rules down.
final class LapPlannerTests: XCTestCase {

    // MARK: - Only natural completion starts a lap

    func testNonIdleStatesNeverStartALap() {
        for state in ["moving", "paused", "stopped", "failed", ""] {
            XCTAssertEqual(
                LapPlanner.decide(state: state, wasRunning: true,
                                  savedRouteRemaining: 3,
                                  dwellRemaining: nil,
                                  multiStopRemaining: nil),
                .ignore,
                "state \(state) should not drive lap continuation")
        }
    }

    /// v1.15.2 audit (L5): the daemon used to broadcast "idle" when it
    /// stopped a runner on the user's behalf — including the stop that
    /// is part of the next lap's own teleport. That second "idle"
    /// decremented the counter again, so three laps ran as two. The
    /// daemon now says "stopped" for that, and this is the assertion
    /// that keeps it that way.
    func testAUserDrivenStopIsNotACompletedLap() {
        XCTAssertEqual(
            LapPlanner.decide(state: "stopped", wasRunning: true,
                              savedRouteRemaining: nil,
                              dwellRemaining: nil,
                              multiStopRemaining: 2),
            .ignore)
    }

    func testIdleWithoutAPriorRunIsIgnored() {
        XCTAssertEqual(
            LapPlanner.decide(state: "idle", wasRunning: false,
                              savedRouteRemaining: 2,
                              dwellRemaining: nil,
                              multiStopRemaining: nil),
            .ignore)
    }

    // MARK: - Exactly one engine advances

    func testSavedRouteAdvancesAndDecrementsOnce() {
        XCTAssertEqual(
            LapPlanner.decide(state: "idle", wasRunning: true,
                              savedRouteRemaining: 2,
                              dwellRemaining: nil,
                              multiStopRemaining: nil),
            .advance(engine: .savedRoute, remainingAfter: 1))
    }

    func testMultiStopAdvancesWhenItIsTheOnlyEngine() {
        XCTAssertEqual(
            LapPlanner.decide(state: "idle", wasRunning: true,
                              savedRouteRemaining: nil,
                              dwellRemaining: nil,
                              multiStopRemaining: 2),
            .advance(engine: .multiStop, remainingAfter: 1))
    }

    func testDwellOwnsTheEndOfTheTripEvenWithNoLapsLeft() {
        XCTAssertEqual(
            LapPlanner.decide(state: "idle", wasRunning: true,
                              savedRouteRemaining: nil,
                              dwellRemaining: 0,
                              multiStopRemaining: nil),
            .advance(engine: .dwell, remainingAfter: 0))
    }

    /// Two engines armed at once is how a lap gets navigated twice.
    func testMultiStopStandsDownWhenAnotherEngineIsArmed() {
        for (saved, dwell) in [(3 as Int?, nil as Int?),
                               (0, nil),
                               (nil, 2),
                               (nil, 0)] {
            let outcome = LapPlanner.decide(
                state: "idle", wasRunning: true,
                savedRouteRemaining: saved,
                dwellRemaining: dwell,
                multiStopRemaining: 5)
            if case .advance(let engine, _) = outcome {
                XCTAssertNotEqual(engine, .multiStop,
                                  "multiStop fired alongside another engine")
            }
        }
    }

    // MARK: - Running out

    func testLastLapFinishes() {
        XCTAssertEqual(
            LapPlanner.decide(state: "idle", wasRunning: true,
                              savedRouteRemaining: 0,
                              dwellRemaining: nil,
                              multiStopRemaining: nil),
            .finish)
        XCTAssertEqual(
            LapPlanner.decide(state: "idle", wasRunning: true,
                              savedRouteRemaining: nil,
                              dwellRemaining: nil,
                              multiStopRemaining: 0),
            .finish)
    }

    func testNoEngineAtAllFinishes() {
        XCTAssertEqual(
            LapPlanner.decide(state: "idle", wasRunning: true,
                              savedRouteRemaining: nil,
                              dwellRemaining: nil,
                              multiStopRemaining: nil),
            .finish)
    }

    /// Walking a three-lap trip end to end must yield exactly three
    /// runs — the count that 443c4a8 and the L5 regression both got
    /// wrong, in opposite directions.
    func testThreeLapTripAdvancesExactlyTwice() {
        var remaining: Int? = 2          // laps = 3 -> 2 continuations
        var advances = 0
        while true {
            let outcome = LapPlanner.decide(
                state: "idle", wasRunning: true,
                savedRouteRemaining: nil,
                dwellRemaining: nil,
                multiStopRemaining: remaining)
            if case .advance(_, let after) = outcome {
                advances += 1
                remaining = after
                XCTAssertLessThan(advances, 10, "lap loop did not terminate")
                continue
            }
            XCTAssertEqual(outcome, .finish)
            break
        }
        XCTAssertEqual(advances, 2)
    }
}
