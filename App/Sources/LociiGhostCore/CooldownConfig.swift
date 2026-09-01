import Foundation

/// The user's plausibility settings for jumps.
public struct CooldownConfig: Sendable, Equatable, Codable {
    public var enabled: Bool = false
    /// Fastest movement the user considers plausible between two
    /// positions. 0 turns the speed rule off and leaves only the floor.
    public var maxSpeedKmh: Double = 60 {
        didSet { maxSpeedKmh = max(0, maxSpeedKmh) }
    }
    /// Floor under every jump, however short — the case the speed rule
    /// can't catch: two positions a metre apart, a hundred times a
    /// second.
    public var minimumGapSeconds: Double = 0 {
        didSet { minimumGapSeconds = max(0, minimumGapSeconds) }
    }

    public static let standard = CooldownConfig()

    public init(enabled: Bool = false, maxSpeedKmh: Double = 60,
                minimumGapSeconds: Double = 0) {
        self.enabled = enabled
        self.maxSpeedKmh = max(0, maxSpeedKmh.isFinite ? maxSpeedKmh : 0)
        self.minimumGapSeconds = max(0, minimumGapSeconds.isFinite ? minimumGapSeconds : 0)
    }

    /// The `policy` object for `settings.cooldown`. Snake case is the
    /// daemon's wire vocabulary; translating in one place beats two
    /// spellings of every field.
    public var rpcParameters: [String: AnyCodable] {
        [
            "enabled": AnyCodable(enabled),
            "max_speed_kmh": AnyCodable(max(0, maxSpeedKmh)),
            "minimum_gap_s": AnyCodable(max(0, minimumGapSeconds)),
        ]
    }
}
