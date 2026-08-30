import Foundation

/// Which of the three lap engines owns the next lap.
///
/// LociiGhost drives repeated trips three different ways depending on
/// how the trip was started, and each keeps its own remaining-laps
/// counter on `AppState`:
///
/// - ``savedRoute`` — playback of a stored Route (`loopContext`). The
///   daemon runs one lap; the app teleports back and re-fires.
/// - ``dwell`` — multi-stop with "pause at each stop" enabled
///   (`dwellContext`). Owns the end of the trip even on the final lap,
///   because it has to dwell at the last stop before deciding anything.
/// - ``multiStop`` — multi-stop without dwell (`multiStopLapContext`).
public enum LapEngine: String, Sendable, Equatable, CaseIterable {
    case savedRoute
    case dwell
    case multiStop
}

/// What should happen when the daemon reports a state change.
public enum LapOutcome: Sendable, Equatable {
    /// Not a natural completion — nothing to decide.
    case ignore
    /// `engine` takes the next lap; its counter becomes `remainingAfter`.
    case advance(engine: LapEngine, remainingAfter: Int)
    /// The trip is over: play the chime, clear saved progress, drop the
    /// navigation view model.
    case finish
}

/// Decides which lap engine (if any) continues after a daemon state
/// change.
///
/// This exists as a free-standing pure function because the same
/// decision has been got wrong twice — commit 443c4a8 fixed multi-stop
/// with `lapCount > 1` only walking once, and the v1.15.2 audit found
/// the replacement double-counting a lap whenever the teleport's own
/// state change raced the navigate reply. Both were invisible to the
/// test suite because the logic lived inside a 5000-line `@MainActor`
/// class that nothing could instantiate. Keeping the decision here
/// makes it testable; `AppState` keeps the effects.
public enum LapPlanner {

    /// - Parameters:
    ///   - state: the daemon's reported state. Only `"idle"` counts as
    ///     natural completion. `"stopped"` is a user cancel and
    ///     `"failed"` is a dead channel — neither should start a lap,
    ///     which is exactly why the daemon stopped conflating them.
    ///   - wasRunning: whether the app believed a trip was in flight
    ///     immediately before this event.
    ///   - savedRouteRemaining: `loopContext?.remainingLaps`, or nil.
    ///   - dwellRemaining: `dwellContext?.remainingDwellLaps`, or nil.
    ///   - multiStopRemaining: `multiStopLapContext?.remainingLaps`,
    ///     or nil.
    public static func decide(
        state: String,
        wasRunning: Bool,
        savedRouteRemaining: Int?,
        dwellRemaining: Int?,
        multiStopRemaining: Int?
    ) -> LapOutcome {
        guard state == "idle", wasRunning else { return .ignore }

        // Saved-route playback wins when it is present at all.
        if let remaining = savedRouteRemaining {
            return remaining > 0
                ? .advance(engine: .savedRoute, remainingAfter: remaining - 1)
                : .finish
        }

        // Dwell owns the end of the trip either way: even with no laps
        // left it must sleep at the final stop before finishing, so the
        // completion chime is its call, not ours.
        if let remaining = dwellRemaining {
            return .advance(engine: .dwell,
                            remainingAfter: max(0, remaining - 1))
        }

        // Multi-stop only runs when neither other engine is armed —
        // otherwise two of them fire on the same idle and the trip
        // double-navigates.
        if let remaining = multiStopRemaining {
            return remaining > 0
                ? .advance(engine: .multiStop, remainingAfter: remaining - 1)
                : .finish
        }

        return .finish
    }
}
