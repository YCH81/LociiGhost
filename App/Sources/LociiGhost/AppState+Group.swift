import Foundation
import LociiGhostCore

// Group sync: several iPhones on one run.
//
// The whole client side is this file, because the daemon put the
// fan-out in the location service every mover already writes to. So
// there is nothing to add per mode — each movement call passes the
// same `group` object, or doesn't.

extension AppState {

    /// The `group` parameter for a movement call, or nil when there is
    /// no group to apply.
    ///
    /// `leader` is the device the call is about; it is always in the
    /// group and always first, because the run's status, events and
    /// Stop belong to that session.
    func groupParams(leader: String) -> [String: AnyCodable]? {
        guard groupSyncEnabled, leader != Self.virtualMapUDID else { return nil }
        var udids = [leader]
        for udid in groupUDIDs where udid != leader && udid != Self.virtualMapUDID {
            udids.append(udid)
        }
        guard udids.count > 1 else { return nil }
        // Remember who actually leads this run. The sidebar reads it
        // for the role colours, and it must not follow the selection:
        // clicking a follower to watch its map does not promote it.
        activeGroup = ActiveGroup(leader: leader, followers: Array(udids.dropFirst()))
        // Say it out loud. Group sync is invisible when it works and
        // equally invisible when it doesn't — "I ticked the boxes and
        // nothing synced" is unfalsifiable without this line, because
        // the user cannot see whether the group was attached to the
        // call or silently dropped on the way.
        showInfo(String(
            format: String(localized: "Group sync: moving %lld iPhones together.",
                           comment: "Toast when a run goes out to a device group"),
            udids.count))
        return ["udids": AnyCodable(udids.map { AnyCodable($0) })]
    }

    /// Devices that would move together right now, for the UI to show.
    /// A member that isn't connected is listed but flagged: the daemon
    /// skips it rather than refusing the run, and the user should see
    /// which of their phones is about to be left behind.
    var groupMembership: [(udid: String, name: String, connected: Bool)] {
        guard let leader = selectedUDID else { return [] }
        var seen = Set<String>()
        var out: [(String, String, Bool)] = []
        for udid in [leader] + groupUDIDs where seen.insert(udid).inserted {
            let device = devices.first { $0.udid == udid }
            out.append((udid, device?.name ?? udid, device?.connected == true))
        }
        return out
    }

    /// Which part a phone plays in the group, or nil when the group
    /// isn't doing anything.
    ///
    /// One place, deliberately: the sidebar colours the glyph and
    /// labels the card from this, and a second copy of "is this the
    /// leader" living in a view is how the flower-mode click rule
    /// ended up fixed in one spot and broken in five.
    ///
    /// Returns nil unless sync is on AND there is at least one
    /// follower — a group of one leads nobody, and marking the
    /// selected phone "leading" in that state says something untrue.
    func groupRole(for udid: String) -> GroupRole? {
        // While a group run exists, the roles are the ones it started
        // with. Deriving them from `selectedUDID` instead — as the
        // first version did — meant clicking a follower to look at its
        // map recomputed the whole group around it: the follower became
        // "the leader", its own follower list came out empty, and every
        // badge vanished mid-run while the phones carried on moving in
        // formation.
        //
        // Nor can this be gated on `anySessionActive`, which the second
        // attempt did: MainView nils `navigation` and `joystick` on
        // every device switch, so that flag goes false the instant you
        // click a follower — the very moment the roles are being asked
        // for. `activeGroup` is cleared by the stop paths and by the
        // leader's terminal state event instead.
        if let group = activeGroup {
            guard !group.followers.isEmpty else { return nil }
            if udid == group.leader { return .leading }
            return group.followers.contains(udid) ? .following : nil
        }

        // Nothing running yet: describe the group as configured. The
        // leader is the phone it was set up on, pinned when sync was
        // switched on, so browsing the followers doesn't rewrite it.
        // Falls back to the selection only when nothing was pinned.
        guard groupSyncEnabled else { return nil }
        let pinned = plannedGroupLeader.flatMap { candidate in
            devices.contains { $0.udid == candidate } ? candidate : nil
        }
        guard let leader = pinned ?? selectedUDID,
              leader != Self.virtualMapUDID else { return nil }
        let followers = groupUDIDs.filter { $0 != leader && $0 != Self.virtualMapUDID }
        guard !followers.isEmpty else { return nil }
        if udid == leader { return .leading }
        return followers.contains(udid) ? .following : nil
    }

    /// Cut the followers loose from a run that is already moving.
    ///
    /// The leader carries on — that is what distinguishes turning sync
    /// off from pressing Stop. The followers simply stop being written
    /// to and hold their last position, the same thing Stop does for a
    /// single phone.
    ///
    /// Safe to call when nothing is running: the daemon reports an
    /// empty `dropped` list and we say nothing.
    @MainActor
    func detachFollowersFromRunningRun() async {
        guard let client, let leader = selectedUDID,
              leader != Self.virtualMapUDID else { return }
        struct DetachReply: Decodable { let dropped: [String] }
        do {
            let reply: DetachReply = try await client.call(
                "location.group_detach", params: ["udid": AnyCodable(leader)])
            activeGroup = nil
            guard !reply.dropped.isEmpty else { return }
            showInfo(String(
                format: String(localized: "Group sync off — %lld phone(s) stopped, this one keeps going.",
                               comment: "Toast when group sync is switched off during a run"),
                reply.dropped.count))
        } catch {
            // Nothing was moving, or the daemon is gone. Neither is
            // worth a red toast over a toggle the user just flipped.
            NSLog("LociiGhost: group_detach failed: %@", String(describing: error))
        }
    }

    /// Add or remove one device from the group. The selected device is
    /// never a member in its own right — it leads whatever run starts,
    /// so storing it would mean the list changed meaning every time the
    /// user switched phones.
    func toggleGroupMember(_ udid: String) {
        if plannedGroupLeader == nil || plannedGroupLeader == udid {
            // Adding a follower from a phone makes that phone the one
            // the group is being built on.
            plannedGroupLeader = selectedUDID
        }
        if let index = groupUDIDs.firstIndex(of: udid) {
            groupUDIDs.remove(at: index)
        } else if udid != selectedUDID {
            groupUDIDs.append(udid)
        }
    }
}
