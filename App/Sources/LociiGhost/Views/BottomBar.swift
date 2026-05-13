import SwiftUI

/// Persistent control strip pinned to the bottom of the main window.
///
/// Shows the currently selected device and exposes the actions that should
/// always be one click away: restore real GPS, disconnect, refresh. We
/// deliberately keep this bar visible even when no device is selected --
/// the empty state itself is information ("connect a device to begin").
struct BottomBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            statusBlock
            Spacer()
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusBlock: some View {
        if let active = activeDevice {
            HStack(spacing: 8) {
                Circle()
                    .fill(active.connected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.name)
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        Text("\(active.udid.prefix(8))… · iOS \(active.iosVersion) · \(active.transport.uppercased())")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(devModeColor(for: active))
                                .frame(width: 6, height: 6)
                            Text(active.developerModeLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            Text("No device selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func devModeColor(for device: DeviceVM) -> Color {
        switch device.developer_mode {
        case .some(true):  return .green
        case .some(false): return .orange
        case .none:        return .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        // ViewThatFits picks the widest variant that fits, falling
        // back to icon-only `Label` rendering when the window is too
        // narrow to show every button's text label. Each variant
        // returns the SAME button tree from `actionsContent` — just
        // styled differently — so behaviour is identical no matter
        // which one the layout chose. Tooltips remain helpful in the
        // icon-only mode.
        ViewThatFits(in: .horizontal) {
            actionsContent
                .labelStyle(.titleAndIcon)
            actionsContent
                .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private var actionsContent: some View {
        // The bottom bar's job since v1.4 is "live navigation
        // controls" only — Restore / Disconnect / Refresh / Quit
        // moved up to TopStatusBar. This keeps the bottom strip
        // focused on the iPhone's CURRENT motion: pace, profile,
        // pause/stop. Connect lives here as the natural twin of
        // the device chip on the left of this same bar.
        HStack(spacing: 8) {
            if let active = activeDevice, active.connected {
                if let nav = state.navigation {
                    navigationProgress(nav: nav)
                    Divider().frame(height: 22)
                }
                travelModePicker(udid: active.udid)
                Divider().frame(height: 22)
                pauseButton(udid: active.udid)
                stopButton(udid: active.udid)
            }

            if let active = activeDevice, !active.connected {
                Button {
                    Task { await state.connect(udid: active.udid) }
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        // `.large` is the biggest controlSize macOS gives us —
        // these are the primary day-to-day navigation buttons,
        // they should be the easiest things to click in the
        // whole window.
        .controlSize(.large)
        .buttonStyle(.bordered)
    }

    /// Profile switcher that adapts to context:
    ///
    /// * During navigation — hot-swaps speed via the daemon's `apply_speed`
    ///   so the iPhone speeds up / slows down on the next tick.
    /// * When idle — just updates the *default* profile for whatever the
    ///   user picks next, no RPC.
    private func travelModePicker(udid: String) -> some View {
        let activeNav = state.navigation
        let binding = Binding<TravelProfile>(
            get: { activeNav?.profile ?? state.travelProfile },
            set: { newProfile in
                if state.navigation != nil {
                    Task { await state.changeNavigationProfile(udid: udid, to: newProfile) }
                } else {
                    state.travelProfile = newProfile
                }
            }
        )
        return Picker("", selection: binding) {
            ForEach(TravelProfile.allCases) { p in
                Image(systemName: p.symbol).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
        .help(activeNav == nil
              ? "Default travel mode for the next Navigate."
              : "Change travel mode mid-route. Speed updates immediately; route stays the same.")
    }

    @ViewBuilder
    private func pauseButton(udid: String) -> some View {
        if let nav = state.navigation, nav.isPaused {
            Button {
                Task { await state.resumeNavigation(udid: udid) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .help("Continue navigation")
        } else {
            Button {
                Task { await state.pauseNavigation(udid: udid) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(state.navigation == nil)
            .help(state.navigation == nil
                  ? "No active navigation to pause."
                  : "Hold position; iPhone stays where it currently is.")
        }
    }

    /// Stop the current trip. Always calls `stopNavigation` — the
    /// user reported the previous "double-click flips into Restore"
    /// behaviour was confusing and accidentally yanked the iPhone
    /// back to real GPS. New rule: Stop is Stop, no matter how many
    /// times you click it. Restore Real GPS lives on its own button
    /// in the top status bar A and is the only path to that action.
    private func stopButton(udid: String) -> some View {
        Button(role: .destructive) {
            Task { await state.stopNavigation(udid: udid) }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .foregroundStyle(.red)
                .fontWeight(.semibold)
        }
        // `.tint(.red)` on a `.bordered` button paints the chip's
        // background tint, AND `.foregroundStyle(.red)` on the
        // Label inside makes the icon+text themselves red as
        // well — together the button reads as a clear "this is
        // the destructive one" affordance even at a glance.
        // The `.destructive` role is kept so accessibility
        // tools still announce it as such.
        .tint(.red)
        .help(LocalizedStringKey("End navigation; iPhone stays at last simulated position."))
    }

    private func navigationProgress(nav: NavigationVM) -> some View {
        HStack(spacing: 10) {
            Image(systemName: nav.isPaused ? "pause.circle.fill" : nav.profile.symbol)
                .foregroundStyle(nav.isPaused ? .orange : .green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(progressLabel(nav))
                        .font(.callout.monospacedDigit())
                    if nav.laps > 1 {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Lap \(nav.currentLap) / \(nav.laps)")
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.lociSage.opacity(0.15), in: .capsule)
                        .foregroundStyle(Color.lociSage)
                    }
                }
                Text("ETA \(formatDuration(nav.etaSeconds))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: nav.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func progressLabel(_ nav: NavigationVM) -> String {
        let traveled = nav.distanceM * nav.progress
        if nav.distanceM > 1_000 {
            return String(format: "%.2f / %.2f km", traveled / 1_000, nav.distanceM / 1_000)
        }
        return String(format: "%.0f / %.0f m", traveled, nav.distanceM)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var activeDevice: DeviceVM? {
        guard let udid = state.selectedUDID else { return nil }
        return state.devices.first(where: { $0.udid == udid })
    }
}
