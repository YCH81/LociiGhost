import Foundation

/// The flower-mode settings, as the app holds them.
///
/// The daemon has the same nine numbers in `flower_plan.FlowerSettings`
/// and clamps them authoritatively — this type exists so the UI can
/// offer only values the daemon will accept, and so a saved
/// configuration survives a relaunch. The bounds below are pinned to
/// the daemon's by `test_settings_bounds_match_the_app` on the Python
/// side, which reads this file: two copies of a limit that can drift
/// silently is exactly how a stepper ends up offering 200 segments
/// that quietly become 20.
///
/// What is deliberately NOT here: how long a run takes. That is one
/// generator in the daemon feeding both the estimate and the run, and
/// a second implementation in Swift would be a second answer.
public struct FlowerConfig: Sendable, Equatable, Codable {
    public static let segmentRange = 3...20
    public static let lapRange = 0.5...50.0
    public static let lapStep = 0.5
    public static let roundRange = 1...999
    public static let radiusRange = 1.0...2_000.0

    // Each observer clamps its own property. Assigning to a property
    // inside its own `didSet` doesn't re-enter the observer, so this
    // is the whole rule: the UI can write any value from any control
    // and the struct is never out of range, including on the paths
    // that don't go through `init` — which is most of them, since the
    // panel binds straight to these.
    public var radiusM: Double { didSet { radiusM = Self.clamp(radiusM, Self.radiusRange) } }
    public var segments: Int {
        didSet {
            segments = min(max(segments, Self.segmentRange.lowerBound),
                           Self.segmentRange.upperBound)
        }
    }
    public var laps: Double { didSet { laps = Self.snapLaps(laps) } }
    public var rounds: Int {
        didSet {
            rounds = min(max(rounds, Self.roundRange.lowerBound),
                         Self.roundRange.upperBound)
        }
    }
    public var waitBeforeSeconds: Double { didSet { waitBeforeSeconds = max(0, waitBeforeSeconds) } }
    public var waitAfterSeconds: Double { didSet { waitAfterSeconds = max(0, waitAfterSeconds) } }
    public var dwellSeconds: Double { didSet { dwellSeconds = max(0, dwellSeconds) } }
    public var speedMps: Double { didSet { speedMps = max(0.1, speedMps) } }
    public var teleportBetween: Bool

    public static let standard = FlowerConfig()

    public init(
        radiusM: Double = 40,
        segments: Int = 8,
        laps: Double = 1,
        rounds: Int = 1,
        waitBeforeSeconds: Double = 0,
        waitAfterSeconds: Double = 0,
        dwellSeconds: Double = 0,
        speedMps: Double = 1.4,
        teleportBetween: Bool = false,
    ) {
        self.radiusM = Self.clamp(radiusM, Self.radiusRange)
        self.segments = min(max(segments, Self.segmentRange.lowerBound),
                            Self.segmentRange.upperBound)
        self.laps = Self.snapLaps(laps)
        self.rounds = min(max(rounds, Self.roundRange.lowerBound),
                          Self.roundRange.upperBound)
        self.waitBeforeSeconds = max(0, waitBeforeSeconds)
        self.waitAfterSeconds = max(0, waitAfterSeconds)
        self.dwellSeconds = max(0, dwellSeconds)
        self.speedMps = max(0.1, speedMps)
        self.teleportBetween = teleportBetween
    }

    /// Half-lap granularity, rounding halves up.
    ///
    /// `rounded()` in Swift rounds half away from zero, which is what
    /// we want here and is *not* what Python's `round` does — the
    /// daemon spells the same rule as `floor(x + 0.5)` for exactly
    /// that reason.
    public static func snapLaps(_ raw: Double) -> Double {
        guard raw.isFinite else { return 1 }
        let snapped = (raw / lapStep).rounded() * lapStep
        return clamp(snapped, lapRange)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Decoding routes through the clamping initialiser.
    ///
    /// The synthesised `init(from:)` assigns the stored properties
    /// directly, so a settings blob written by a newer build — or
    /// edited by hand — would come back holding values the daemon
    /// will clamp anyway, and the UI would show a stepper sitting
    /// outside its own range.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            radiusM: try container.decode(Double.self, forKey: .radiusM),
            segments: try container.decode(Int.self, forKey: .segments),
            laps: try container.decode(Double.self, forKey: .laps),
            rounds: try container.decode(Int.self, forKey: .rounds),
            waitBeforeSeconds: try container.decode(Double.self, forKey: .waitBeforeSeconds),
            waitAfterSeconds: try container.decode(Double.self, forKey: .waitAfterSeconds),
            dwellSeconds: try container.decode(Double.self, forKey: .dwellSeconds),
            speedMps: try container.decode(Double.self, forKey: .speedMps),
            teleportBetween: try container.decode(Bool.self, forKey: .teleportBetween),
        )
    }

    /// How many orbit vertices one waypoint gets. Shown next to the
    /// laps stepper so "1.5 laps of 8" reads as a number of stops
    /// rather than as arithmetic the user has to do.
    public var verticesPerPoint: Int {
        Int((Double(segments) * laps + 0.5).rounded(.down))
    }

    /// The `settings` object for `location.flower` and
    /// `location.flower_estimate`. Snake case because that is the
    /// daemon's wire vocabulary, and translating in one place beats
    /// two spellings of every field.
    public var rpcParameters: [String: Double] {
        [
            "radius_m": radiusM,
            "segments": Double(segments),
            "laps": laps,
            "rounds": Double(rounds),
            "wait_before_s": waitBeforeSeconds,
            "wait_after_s": waitAfterSeconds,
            "dwell_s": dwellSeconds,
            "speed_mps": speedMps,
        ]
    }
}
