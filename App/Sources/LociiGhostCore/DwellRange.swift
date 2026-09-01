import Foundation

/// How long to pause at each stop, as a range rather than a number.
///
/// A fixed pause at every stop is the tell: real people don't stand
/// still for exactly eight seconds twelve times in a row. So the dwell
/// is drawn per stop from `min...max`.
///
/// The reason this is a type and not two loose `Int`s is that the same
/// range has to answer two different questions, and they have to agree:
///
///   * **What do we actually wait at this stop?** — `pick()`, drawn
///     fresh each time.
///   * **How long will the whole trip take?** — `expectedSeconds`,
///     which has to be the mean of that same draw or the ETA drifts
///     from reality by a little bit at every stop.
///
/// That pairing is exactly the shape of bug the v1.15.2 audit kept
/// finding: one rule, two implementations, and only one of them gets
/// fixed. Keeping both answers on one type means a change to the draw
/// can't silently leave the estimate behind.
public struct DwellRange: Sendable, Equatable, Codable {

    /// Shortest pause, in seconds. Always >= 1.
    public private(set) var minSeconds: Int
    /// Longest pause, in seconds. Always >= `minSeconds`.
    public private(set) var maxSeconds: Int

    /// The default the UI offers: a 5-20 second pause per stop.
    public static let standard = DwellRange(min: 5, max: 20)

    /// Normalises on the way in, so no caller downstream has to think
    /// about reversed or zero bounds: values below 1 clamp to 1, and a
    /// reversed pair is swapped rather than rejected. A range is a
    /// setting a person types into two boxes; typing them in the wrong
    /// order is not an error worth surfacing.
    public init(min: Int, max: Int) {
        let lo = Swift.max(1, Swift.min(min, max))
        let hi = Swift.max(1, Swift.max(min, max))
        self.minSeconds = lo
        self.maxSeconds = hi
    }

    /// A range that always yields the same number — the pre-v1.17
    /// behaviour, and what migrating an old fixed setting produces.
    public init(fixed seconds: Int) {
        self.init(min: seconds, max: seconds)
    }

    /// True when the range can only produce one value.
    public var isFixed: Bool { minSeconds == maxSeconds }

    /// One dwell, drawn uniformly. Takes the generator explicitly so
    /// tests can pin the draw instead of asserting on a distribution.
    public func pick<G: RandomNumberGenerator>(using generator: inout G) -> Int {
        guard !isFixed else { return minSeconds }
        return Int.random(in: minSeconds...maxSeconds, using: &generator)
    }

    /// One dwell, drawn from the system generator.
    public func pick() -> Int {
        var g = SystemRandomNumberGenerator()
        return pick(using: &g)
    }

    /// The mean of `pick()`, for estimating a whole trip.
    ///
    /// Uniform over an integer range, so the mean is the midpoint —
    /// and it stays a `Double` rather than rounding here, because a
    /// half-second of bias per stop across forty stops is twenty
    /// seconds of ETA error.
    public var expectedSeconds: Double {
        (Double(minSeconds) + Double(maxSeconds)) / 2.0
    }

    /// Total expected pause time across `count` stops.
    public func expectedTotal(stops count: Int) -> Double {
        guard count > 0 else { return 0 }
        return expectedSeconds * Double(count)
    }
}
