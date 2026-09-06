import Foundation
import LociiGhostCore

// Flower mode: orbit each waypoint, lap after lap.
//
// The daemon owns the plan and the estimate — one generator feeds both
// the total shown here and the run itself, so this file never computes
// how long anything takes. It asks.

/// Live view of a running flower session.
struct FlowerRunVM: Equatable {
    var current: Coordinate
    var stepIndex: Int
    var totalSteps: Int
    var pointIndex: Int
    var roundIndex: Int
    var rounds: Int
    var points: Int
    var etaSeconds: Double
    var plannedPath: [Coordinate]
    var isMoving: Bool
    /// Held by the user rather than finished. Kept apart from
    /// `!isMoving`, which is also true while a run is waiting out a
    /// dwell — the toolbar must offer Resume for one and not the other.
    var isPaused: Bool

    /// 0…1 for the progress bar. Guarded because a plan of zero steps
    /// would otherwise divide by zero the moment a run is set up with
    /// no waypoints.
    var progress: Double {
        totalSteps > 0 ? min(1, Double(stepIndex) / Double(totalSteps)) : 0
    }
}

/// What the settings panel shows before anything starts.
struct FlowerEstimate: Equatable {
    var steps: Int
    var verticesPerPoint: Int
    var points: Int
    var rounds: Int
    var seconds: Double
}

extension AppState {

    // MARK: - Estimate

    /// Ask the daemon what this configuration would cost.
    ///
    /// The RPC deliberately touches no device: the panel is open before
    /// anything is connected, and an estimate that needed a phone would
    /// be an estimate nobody sees.
    @MainActor
    func estimateFlower(points: [Coordinate],
                        from origin: Coordinate? = nil) async -> FlowerEstimate? {
        guard let client, !points.isEmpty else { return nil }
        struct Reply: Decodable {
            let steps: Int
            let vertices_per_point: Int
            let points: Int
            let rounds: Int
            let seconds: Double
        }
        var params: [String: AnyCodable] = [
            "points": AnyCodable(Self.wirePoints(points)),
            "settings": AnyCodable(Self.wireSettings(flowerConfig)),
        ]
        if let origin {
            params["origin_lat"] = AnyCodable(origin.lat)
            params["origin_lng"] = AnyCodable(origin.lng)
        }
        do {
            let reply: Reply = try await client.call("location.flower_estimate", params: params)
            return FlowerEstimate(steps: reply.steps,
                                  verticesPerPoint: reply.vertices_per_point,
                                  points: reply.points,
                                  rounds: reply.rounds,
                                  seconds: reply.seconds)
        } catch {
            // A failed estimate is not worth a red toast: the user is
            // still typing, and the panel simply shows nothing yet.
            return nil
        }
    }

    // MARK: - Run

    @MainActor
    func startFlower(udid: String, points: [Coordinate], resumeFromStep: Int = 0) async {
        if udid == Self.virtualMapUDID { return }
        guard let client else { return }
        guard !points.isEmpty else {
            lastError = String(
                localized: "Add at least one waypoint before starting flower mode.",
                comment: "Toast when flower mode is started with no waypoints")
            return
        }
        do {
            let reply: FlowerStatusReply = try await client.call(
                "location.flower",
                params: flowerParams(udid: udid, points: points,
                                     resumeFromStep: resumeFromStep))
            flowerRun = Self.runVM(from: reply)
            // Drop the other modes locally: the daemon already stopped
            // them, and leaving their view state up would render two
            // runs at once.
            navigation = nil
            randomWalk = nil
            joystick = nil
            setSimulatedLocation(Coordinate(lat: reply.lat, lng: reply.lng), for: udid)
        } catch {
            lastError = String(describing: error)
        }
    }

    @MainActor
    func stopFlower(udid: String) async {
        // Stopping the leader ends the formation; the sidebar should
        // stop calling anyone a follower the moment it does.
        if activeGroup?.leader == udid { activeGroup = nil }
        flowerRun = nil
        guard let client else { return }
        do {
            struct StopReply: Decodable { let ok: Bool }
            let _: StopReply = try await client.call(
                "location.stop", params: ["udid": AnyCodable(udid)])
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Restart a run where it left off — the daemon re-plans (the plan
    /// is deterministic in waypoints and settings) and skips ahead, so
    /// resuming needs one integer rather than a stored route.
    @MainActor
    func resumeFlower(udid: String, points: [Coordinate]) async {
        let step = flowerRun?.stepIndex ?? 0
        await startFlower(udid: udid, points: points, resumeFromStep: step)
    }

    private func flowerParams(udid: String,
                             points: [Coordinate],
                             resumeFromStep: Int) -> [String: AnyCodable] {
        var params: [String: AnyCodable] = [
            "udid": AnyCodable(udid),
            "points": AnyCodable(Self.wirePoints(points)),
            "settings": AnyCodable(Self.wireSettings(flowerConfig)),
            "resume_from_step": AnyCodable(resumeFromStep),
        ]
        if let group = groupParams(leader: udid) {
            params["group"] = AnyCodable(group)
        }
        return params
    }

    /// `AnyCodable` carries only scalars, `[AnyCodable]` and
    /// `[String: AnyCodable]`, so nested JSON has to be built rather
    /// than handed over as `[String: Any]` — which compiles as a
    /// generic `T` and then throws at encode time, at the point where
    /// the user pressed Start.
    static func wirePoints(_ points: [Coordinate]) -> [AnyCodable] {
        points.map {
            AnyCodable(["lat": AnyCodable($0.lat), "lng": AnyCodable($0.lng)])
        }
    }

    static func wireSettings(_ config: FlowerConfig) -> [String: AnyCodable] {
        var out = config.rpcParameters.mapValues { AnyCodable($0) }
        out["teleport_between"] = AnyCodable(config.teleportBetween)
        return out
    }

    // MARK: - Events

    /// Fold a status broadcast into `flowerRun`.
    ///
    /// Both `event.position_update` and `event.state_changed` carry the
    /// runner's whole status, and it is the same shape the start reply
    /// has — so this re-decodes the event through that one struct
    /// rather than reading twelve fields out of the params dictionary
    /// by hand. An event from some other source simply fails to decode
    /// and is ignored, which is the correct outcome.
    @MainActor
    func applyFlowerEvent(_ params: [String: AnyCodable]) {
        guard flowerRun != nil,
              let data = try? JSONEncoder().encode(params),
              let reply = try? JSONDecoder().decode(FlowerStatusReply.self, from: data)
        else { return }
        if reply.state == "stopped" {
            flowerRun = nil
            return
        }
        flowerRun = Self.runVM(from: reply)
    }

    static func runVM(from reply: FlowerStatusReply) -> FlowerRunVM {
        FlowerRunVM(
            current: Coordinate(lat: reply.lat, lng: reply.lng),
            stepIndex: reply.step_index,
            totalSteps: reply.total_steps,
            pointIndex: reply.point_index,
            roundIndex: reply.round_index,
            rounds: reply.rounds,
            points: reply.points,
            etaSeconds: reply.eta_seconds,
            plannedPath: (reply.planned_path ?? []).map {
                Coordinate(lat: $0.lat, lng: $0.lng)
            },
            isMoving: reply.state == "moving",
            isPaused: reply.state == "paused",
        )
    }
}

/// The runner's status, as it arrives on the wire.
struct FlowerStatusReply: Decodable {
    struct Coord: Decodable { let lat: Double; let lng: Double }
    let state: String
    let lat: Double
    let lng: Double
    let step_index: Int
    let total_steps: Int
    let point_index: Int
    let round_index: Int
    let rounds: Int
    let points: Int
    let eta_seconds: Double
    let planned_path: [Coord]?
}
