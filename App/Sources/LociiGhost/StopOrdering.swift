import Foundation

/// v1.11.2: TSP-style minimum-distance reorder for staged stops.
/// Shared between MultiStopPanel (sidebar) and ControlPanel (on-map
/// popup) so both surfaces offer the same Smart sort affordance.
///
/// Namespace as an `enum` (no cases) so the helper functions feel
/// scoped — `StopOrdering.smartSorted(...)` reads better than a
/// loose `smartSortedStops(...)` floating at module scope.
///
/// All functions are pure: input coords in, sorted coords out, no
/// shared state, no UI access. Safe to call from any thread.
enum StopOrdering {
    /// Reorder `stops` to minimise total path distance via haversine.
    /// `stops[0]` stays fixed as the start. Open path (no return to
    /// the start). Returns the input unchanged when `count < 3` since
    /// any 1- or 2-stop ordering is already optimal.
    static func smartSorted(_ stops: [Coordinate]) -> [Coordinate] {
        guard stops.count > 2 else { return stops }
        if stops.count <= 10 {
            return bruteForceMinPath(stops)
        } else {
            return nearestNeighborThen2Opt(stops)
        }
    }

    /// Enumerate every permutation of `stops[1...]` and keep the one
    /// with minimum total haversine distance from `stops[0]`. 9! =
    /// 362_880 permutations at the N=10 boundary — well under a
    /// second on any modern Mac.
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
    /// single swap and one yield per step (no array copies). The
    /// closure receives the current arrangement each call.
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

    /// Nearest-neighbor greedy seed → 2-opt local search until no
    /// improving swap exists. For N > 10 brute force becomes
    /// factorial-cost; 2-opt typically lands within a few percent of
    /// optimal on realistic geographic inputs.
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
            current = path.last!
        }
        // 2-opt: reverse every sub-segment [i...j] and keep the swap
        // if it strictly shortens the path. Restart the outer loop
        // after any improvement so cascading wins aren't missed.
        // i ≥ 1 because the start is pinned at path[0].
        var improved = true
        while improved {
            improved = false
            if path.count < 4 { break }
            outer: for i in 1..<(path.count - 1) {
                for j in (i + 1)..<path.count {
                    if twoOptDelta(path, i: i, j: j) < -1e-6 {
                        path[i...j].reverse()
                        improved = true
                        break outer
                    }
                }
            }
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

    private static func totalPathDistance(start: Coordinate, path: [Coordinate]) -> Double {
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
    static func haversineMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
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
