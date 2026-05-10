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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44)
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
        HStack(spacing: 6) {
            if let active = activeDevice, active.connected {
                // Live progress only when there's an actual navigation.
                if let nav = state.navigation {
                    navigationProgress(nav: nav)
                    Divider().frame(height: 16)
                }

                // Profile picker / pause / stop are PERMANENT here as a
                // safety surface. Even after a daemon restart wipes the
                // app's `navigation` state, the iPhone may still be
                // frozen at a simulated location -- the user needs a
                // visible kill switch they can click without first
                // having to reconnect or start a fake nav.
                travelModePicker(udid: active.udid)
                Divider().frame(height: 16)
                pauseButton(udid: active.udid)
                stopButton(udid: active.udid)
                Divider().frame(height: 16)

                Button {
                    Task { await state.restore(udid: active.udid) }
                } label: {
                    Label("Restore Real GPS", systemImage: "arrow.counterclockwise")
                }
                .help("Stop simulating and let the device report its real location")

                Button(role: .destructive) {
                    Task { await state.disconnect(udid: active.udid) }
                } label: {
                    Label("Disconnect", systemImage: "iphone.slash")
                }
            }

            if let active = activeDevice, !active.connected {
                Button {
                    Task { await state.connect(udid: active.udid) }
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .keyboardShortcut(.defaultAction)
            }

            Button {
                Task { await state.refreshDevices() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-scan for connected devices")

            Divider()
                .frame(height: 16)

            Button {
                state.quitApp()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit LociiGhost. The privileged daemon stays running so the next launch doesn't need the password.")
            .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.small)
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
        .frame(width: 130)
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

    /// Always functional when the device is connected. During an active
    /// trip this is a normal "end navigation" button; when idle it
    /// becomes the panic-stop — clear any stale simulation that survived
    /// a daemon restart or app reload, regardless of whether this app
    /// instance has a NavigationVM for it.
    private func stopButton(udid: String) -> some View {
        let isNavigating = state.navigation != nil
        return Button(role: .destructive) {
            Task {
                if isNavigating {
                    await state.stopNavigation(udid: udid)
                } else {
                    // Emergency stop: clear any ghost simulation that
                    // outlived the navigator (e.g., daemon got restarted
                    // mid-trip).
                    await state.restore(udid: udid)
                }
            }
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .help(isNavigating
              ? "End navigation; iPhone stays at last simulated position."
              : "Panic stop — clears any lingering simulation and returns the iPhone to real GPS.")
    }

    private func navigationProgress(nav: NavigationVM) -> some View {
        HStack(spacing: 8) {
            Image(systemName: nav.isPaused ? "pause.circle.fill" : nav.profile.symbol)
                .foregroundStyle(nav.isPaused ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("\(progressLabel(nav)) · ETA \(formatDuration(nav.etaSeconds))")
                        .font(.caption.monospacedDigit())
                    if nav.laps > 1 {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Lap \(nav.currentLap) / \(nav.laps)")
                        }
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                ProgressView(value: nav.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            }
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
