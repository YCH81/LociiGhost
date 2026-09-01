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

    /// Add or remove one device from the group. The selected device is
    /// never a member in its own right — it leads whatever run starts,
    /// so storing it would mean the list changed meaning every time the
    /// user switched phones.
    func toggleGroupMember(_ udid: String) {
        if let index = groupUDIDs.firstIndex(of: udid) {
            groupUDIDs.remove(at: index)
        } else if udid != selectedUDID {
            groupUDIDs.append(udid)
        }
    }
}
