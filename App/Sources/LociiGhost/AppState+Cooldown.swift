import Foundation
import LociiGhostCore

// The cooldown gate, as the app holds it.
//
// The daemon enforces it — every teleport and every mode start goes
// through the check there, including the ones the phone remote starts,
// which is why the rule can't live here. This side owns the user's
// numbers, persists them, and pushes them down whenever they change.

extension AppState {

    /// Send the current policy to the daemon.
    ///
    /// Called when the user changes it and again after a connect: the
    /// daemon holds it in memory only, deliberately — the Mac owns the
    /// setting, and a second persisted copy down there is a second
    /// thing to keep in step, with no way to tell which one is right.
    @MainActor
    func pushCooldownPolicy() async {
        guard let client else { return }
        do {
            struct Reply: Decodable { let enabled: Bool }
            let _: Reply = try await client.call(
                "settings.cooldown",
                params: ["policy": AnyCodable(cooldownConfig.rpcParameters)])
        } catch {
            // Not worth a toast: the gate is the user's own guard rail,
            // and a daemon too old to know the method simply doesn't
            // have one.
            NSLog("LociiGhost: could not push the cooldown policy: \(error)")
        }
    }

    /// The cooldown code the daemon refuses with.
    static let cooldownErrorCode = -32007

    /// Turn a refusal into the sentence the user sees, or nil when the
    /// error is something else.
    ///
    /// The daemon sends remaining_s / required_s / distance_m as data
    /// precisely so this doesn't have to parse a message string — a
    /// client that did would break the first time the wording changed.
    static func cooldownToast(for error: Error) -> String? {
        guard let rpc = error as? RPCError, rpc.code == cooldownErrorCode else { return nil }
        guard let fields = rpc.data?.value as? [String: AnyCodable] else { return rpc.message }
        let remaining = (fields["remaining_s"]?.value as? Double)
            ?? Double(fields["remaining_s"]?.value as? Int ?? 0)
        let distance = (fields["distance_m"]?.value as? Double)
            ?? Double(fields["distance_m"]?.value as? Int ?? 0)
        return cooldownMessage(remainingSeconds: remaining, distanceM: distance)
    }

    /// Human-readable "why did my teleport not happen".
    ///
    /// The daemon's refusal carries the numbers rather than a sentence,
    /// so the wording lives here where it can be localised — and so a
    /// change to it can't break a client that was parsing seconds out
    /// of a message string.
    static func cooldownMessage(remainingSeconds: Double, distanceM: Double) -> String {
        let seconds = Int(remainingSeconds.rounded(.up))
        let waitLabel = seconds >= 60
            ? String(format: String(localized: "%lld min %lld s",
                                    comment: "Cooldown wait, minutes and seconds"),
                     seconds / 60, seconds % 60)
            : String(format: String(localized: "%lld s",
                                    comment: "Cooldown wait, seconds only"),
                     seconds)
        return String(
            format: String(
                localized: "Cooldown: wait %@ before a jump of %.1f km.",
                comment: "Toast when the cooldown gate refuses a teleport"),
            waitLabel, distanceM / 1000)
    }
}
