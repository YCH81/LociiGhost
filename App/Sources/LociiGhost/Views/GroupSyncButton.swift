import SwiftUI
import LociiGhostCore

/// Group sync, where the devices are.
///
/// It also lives in Settings, but that is where you go once to set
/// something up — this is a per-session choice ("today I'm running
/// these two together"), and it belongs next to the list of phones it
/// is about.
struct GroupSyncButton: View {
    /// Header form: icon plus the member count, no label and no
    /// full-width pill. The row it sits in already says "Devices", so
    /// repeating "Group sync" there costs width the title needs.
    var compact: Bool = false

    @Environment(AppState.self) private var state
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            if compact {
                compactLabel
            } else {
            HStack(spacing: 5) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.caption)
                Text("Group sync", comment: "Sidebar — group sync pill")
                    .font(.caption)
                Spacer(minLength: 0)
                if state.groupSyncEnabled && followerCount > 0 {
                    // The count is the whole status: "on" without a
                    // follower does nothing, and that is exactly the
                    // state someone would otherwise stare at wondering
                    // why nothing is syncing.
                    Text("\(followerCount + 1)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.lociSage.opacity(0.25), in: Capsule())
                } else {
                    Text("off", comment: "Sidebar — group sync is off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(state.groupSyncEnabled && followerCount > 0
                             ? AnyShapeStyle(Color.lociSage)
                             : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 5, changesCursor: false)
        .help(state.groupSyncEnabled && followerCount > 0
              ? "Group sync is on — the selected iPhones move together"
              : "Group sync — move several iPhones together")
        .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
            GroupSyncPopover()
                .environment(state)
        }
    }

    private var compactLabel: some View {
        HStack(spacing: 3) {
            // Deliberately NOT a phone glyph. The wireless-phone
            // symbol this used to carry is the same one a WiFi-
            // connected device shows in the list right below, so the
            // header looked like it was reporting a device state.
            // A link says "these move together" and belongs to
            // nothing else on screen.
            Image(systemName: "link")
            Text("Group sync", comment: "Sidebar — group sync pill")
                .font(.caption2)
            if state.groupSyncEnabled && followerCount > 0 {
                // Same rule as the wide form: the count *is* the
                // status, because "on" with no follower syncs nothing.
                Text("\(followerCount + 1)")
                    .font(.caption2.monospacedDigit())
            }
        }
        .foregroundStyle(state.groupSyncEnabled && followerCount > 0
                         ? AnyShapeStyle(Color.lociSage)
                         : AnyShapeStyle(.secondary))
        .padding(4)
        .contentShape(.rect)
    }

    private var followerCount: Int {
        guard let leader = state.selectedUDID else { return 0 }
        return state.groupUDIDs.filter { $0 != leader }.count
    }
}

/// Who leads, who follows.
private struct GroupSyncPopover: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $state.groupSyncEnabled) {
                Text("Move the selected iPhones together",
                     comment: "Settings — group sync enable toggle")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            if phones.isEmpty {
                Text("No devices yet — connect one first.",
                     comment: "Settings — group sync with no devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Leader on the left, follower on the right, one row
                // per phone. Leading is exclusive because a run belongs
                // to one device — its status, its events and its Stop —
                // so the radio writes `selectedUDID` rather than
                // inventing a second idea of "the current phone" that
                // could disagree with the sidebar.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Leads", comment: "Group popover — column header for the leading device")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Follows", comment: "Group popover — column header for following devices")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("")
                    }
                    ForEach(phones, id: \.udid) { device in
                        GridRow {
                            leaderButton(for: device)
                            followerBox(for: device)
                            deviceLabel(for: device)
                        }
                    }
                }

                Text("A member that isn't connected when a run starts is skipped, and the others carry on.",
                     comment: "Settings — what happens to a disconnected group member")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
        .padding(14)
        .frame(minWidth: 280)
    }

    private var phones: [DeviceVM] {
        state.devices.filter { $0.udid != AppState.virtualMapUDID }
    }

    private func leaderButton(for device: DeviceVM) -> some View {
        let isLeader = state.selectedUDID == device.udid
        return Button {
            state.selectedUDID = device.udid
            // A device can't lead and follow at once.
            state.groupUDIDs.removeAll { $0 == device.udid }
        } label: {
            Image(systemName: isLeader ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isLeader ? AnyShapeStyle(Color.lociSage) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey("This iPhone leads — the run belongs to it"))
    }

    private func followerBox(for device: DeviceVM) -> some View {
        let isLeader = state.selectedUDID == device.udid
        return Toggle(isOn: Binding(
            get: { isLeader || state.groupUDIDs.contains(device.udid) },
            set: { _ in state.toggleGroupMember(device.udid) },
        )) { Text("") }
            .toggleStyle(.checkbox)
            .labelsHidden()
            // The leader is in the group by definition; unticking it
            // would mean "run on this phone but don't move it".
            .disabled(isLeader || !state.groupSyncEnabled)
    }

    private func deviceLabel(for device: DeviceVM) -> some View {
        HStack(spacing: 5) {
            Text(device.name).font(.callout)
            if !device.connected {
                Text("not connected",
                     comment: "Settings — a group member that isn't connected")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
