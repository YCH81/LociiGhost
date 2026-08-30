import Foundation

/// TSP-style minimum-distance reorder for staged stops.
///
/// Shared between MultiStopPanel (sidebar) and ControlPanel (on-map
/// popup) so both surfaces offer the same Smart sort affordance.
///
/// All functions are pure: coords in, sorted coords out, no shared
/// state, no UI access — safe to call from any thread, which the
/// callers now do (see the cost note on `smartSorted`).
public enum StopOrdering {

    /// Above this many stops the brute-force search is skipped.
    ///
    /// v1.15.2 audit (P4): this was 10, i.e. 9! = 362,880 permutations,
    /// each costing 9 haversines — about 3.3M trig calls — run
    /// synchronously on the main actor from a button action. 8 is
    /// 7! = 5,040, roughly seventy times cheaper, and 2-opt handles
    /// the rest within a few percent of optimal on real geography.
    public static let bruteForceLimit = 8

    /// Hard ceiling on 2-opt improvement rounds.
    ///
    /// The previous loop restarted the whole scan after every single
    /// improving swap (`break outer`) and had no bound at all: one
    /// scan is O(n²) haversine pairs and the number of improvements is
    /// itself O(n²), so a pathological input was O(n⁴). The codebase
    /// elsewhere talks about 1163- and 4000-point GPX routes, and
    /// those can be bulk-pasted straight into the stop list.
    public static let maxTwoOptPasses = 200

    /// Reorder `stops` to minimise total path distance via haversine.
    /// `stops[0]` stays fixed as the start. Open path (no return to
    /// the start). Returns the input unchanged when `count < 3` since
    /// any 1- or 2-stop ordering is already optimal.
    ///
    /// Cost is bounded but not small: callers should run this off the
    /// main actor (`Task.detached`) for anything beyond a handful of
    /// stops.
    public static func smartSorted(_ stops: [Coordinate]) -> [Coordinate] {
        guard stops.count > 2 else { return stops }
        if stops.count <= bruteForceLimit {
            return bruteForceMinPath(stops)
        } else {
            return nearestNeighborThen2Opt(stops)
        }
    }

    /// Enumerate every permutation of `stops[1...]` and keep the one
    /// with minimum total haversine distance from `stops[0]`.
    private static func bruteForceMinPath(_ stops: [Coordinate]) -> [Coordinate] {
        let start = stops[0]
        let tail = Array(stops.dropFirst())
        var bestOrder = tail
        var bestDistance = totalPathDistance(start: start, path: tail)
        enumeratePermutations(tail) { perm in
            let d = totalPathDistance(start: start, path: perm)
            if d < bestDistance {
                bestDistance = d
                bestOrder = perm
            }
        }
        return [start] + bestOrder
    }

    /// Heap's algorithm — yields every n! permutation of `arr` with a
    /// single swap per step. The closure receives the current
    /// arrangement each call.
    private static func enumeratePermutations<T>(_ arr: [T], yield: ([T]) -> Void) {
        var a = arr
        func generate(_ k: Int) {
            if k <= 1 {
                yield(a)
                return
            }
            for i in 0..<k {
                generate(k - 1)
                let swapIdx = (k % 2 == 0) ? i : 0
                a.swapAt(swapIdx, k - 1)
            }
        }
        if a.isEmpty { yield(a); return }
        generate(a.count)
    }

    /// Nearest-neighbor greedy seed → bounded 2-opt local search.
    private static func nearestNeighborThen2Opt(_ stops: [Coordinate]) -> [Coordinate] {
        let start = stops[0]
        var remaining = Array(stops.dropFirst())
        var path: [Coordinate] = [start]
        var current = start
        while !remaining.isEmpty {
            var bestI = 0
            var bestD = haversineMeters(current, remaining[0])
            for i in 1..<remaining.count {
                let d = haversineMeters(current, remaining[i])
                if d < bestD { bestD = d; bestI = i }
            }
            path.append(remaining.remove(at: bestI))
            current = path[path.count - 1]
        }
        guard path.count >= 4 else { return path }

        // 2-opt, best-improvement: each pass scans every candidate and
        // applies only the single best one. The old code applied the
        // FIRST improving swap and restarted the scan
        // (`improved = true; break outer`), which converges in far more
        // passes for the same result. i >= 1 because the start is
        // pinned at path[0].
        var passes = 0
        while passes < maxTwoOptPasses {
            passes += 1
            var bestDelta = -1e-6
            var bestI = -1
            var bestJ = -1
            for i in 1..<(path.count - 1) {
                for j in (i + 1)..<path.count {
                    let delta = twoOptDelta(path, i: i, j: j)
                    if delta < bestDelta {
                        bestDelta = delta
                        bestI = i
                        bestJ = j
                    }
                }
            }
            if bestI < 0 { break }          // local optimum
            path[bestI...bestJ].reverse()
        }
        return path
    }

    /// Change in total path length if segment [i...j] is reversed.
    /// For open paths the last edge (j, j+1) is conditional; the
    /// first edge (i-1, i) always exists because i ≥ 1.
    private static func twoOptDelta(_ path: [Coordinate], i: Int, j: Int) -> Double {
        let n = path.count
        var removed = haversineMeters(path[i - 1], path[i])
        var added = haversineMeters(path[i - 1], path[j])
        if j + 1 < n {
            removed += haversineMeters(path[j], path[j + 1])
            added += haversineMeters(path[i], path[j + 1])
        }
        return added - removed
    }

    /// Total open-path length from `start` through `path` in order.
    public static func totalPathDistance(start: Coordinate, path: [Coordinate]) -> Double {
        var d = 0.0
        var prev = start
        for c in path {
            d += haversineMeters(prev, c)
            prev = c
        }
        return d
    }

    /// Great-circle distance in metres. Earth radius 6,371,000 m.
    /// The app's coord system is plain WGS-84 lat/lng — exactly
    /// what haversine expects.
    public static func haversineMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let R = 6_371_000.0
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLng = (b.lng - a.lng) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
                + cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return R * c
    }
}
