import SwiftUI

/// Four-state speed-mode selector binding used by `travelModePicker`.
/// The first three cases map to the three `TravelProfile` presets; the
/// fourth activates the free-form custom-speed override.
private enum SpeedMode: Hashable {
    case preset(TravelProfile)
    case custom
}

/// Persistent control strip pinned to the bottom of the main window.
///
/// Shows the currently selected device and exposes the actions that should
/// always be one click away: restore real GPS, disconnect, refresh. We
/// deliberately keep this bar visible even when no device is selected --
/// the empty state itself is information ("connect a device to begin").
struct BottomBar: View {
    @Environment(AppState.self) private var state
    @State private var showClearStopsAlert = false
    @State private var showClearAllConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            statusBlock
            Spacer()
            // v1.11.2 T35: CustomSpeedField lives OUTSIDE ViewThatFits
            // (same rationale as the old InlineSpeedField — ViewThatFits
            // measures both variant branches, doubling layout cost; keeping
            // it here ensures exactly one measure per body eval). It only
            // appears while a custom speed override is active, so it stays
            // visually adjacent to the 4-segment travel-mode picker in
            // `actionsContent`.
            if let active = activeDevice, active.connected,
               state.customSpeedMps != nil {
                CustomSpeedField(udid: active.udid)
                Divider().frame(height: 22)
            }
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
        // NavigationProgressBlock lives OUTSIDE ViewThatFits so
        // state.navigation (1 Hz) only re-renders that one small
        // block — not the entire ViewThatFits double-measure pass.
        // stableButtons reads only navigationActive / navigationPaused
        // / travelProfile / customSpeedMps, none of which change at
        // 1 Hz, so ViewThatFits only re-measures on session
        // start/stop, pause/resume, or profile changes.
        HStack(spacing: 8) {
            if let active = activeDevice, active.connected,
               state.navigationActive {
                NavigationProgressBlock()
                Divider().frame(height: 22)
            }
            ViewThatFits(in: .horizontal) {
                stableButtons.labelStyle(.titleAndIcon)
                stableButtons.labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder
    private var stableButtons: some View {
        HStack(spacing: 8) {
            if let active = activeDevice, active.connected {
                travelModePicker(udid: active.udid)
                Divider().frame(height: 22)
                pauseButton(udid: active.udid)
                stopButton(udid: active.udid)
                clearButton(udid: active.udid)
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
        .controlSize(.large)
        .buttonStyle(.bordered)
    }

    /// Unified 4-segment travel-mode / speed picker.
    /// Reads only stable flags (navigationActive, travelProfile, customSpeedMps)
    /// so it never re-renders at 1 Hz inside ViewThatFits.
    private func travelModePicker(udid: String) -> some View {
        let binding = Binding<SpeedMode>(
            get: {
                if state.customSpeedMps != nil { return .custom }
                return .preset(state.travelProfile)
            },
            set: { newMode in
                switch newMode {
                case .preset(let profile):
                    state.customSpeedMps = nil
                    if state.navigationActive {
                        Task { await state.changeNavigationProfile(udid: udid, to: profile) }
                    } else {
                        state.travelProfile = profile
                    }
                case .custom:
                    guard state.customSpeedMps == nil else { return }
                    state.customSpeedMps = state.travelProfile.defaultSpeedMps
                    if state.navigationActive {
                        Task { await state.changeNavigationProfile(udid: udid, to: state.travelProfile) }
                    }
                }
            }
        )
        return Picker("", selection: binding) {
            ForEach(TravelProfile.allCases) { p in
                Image(systemName: p.symbol)
                    // labelKey (LocalizedStringKey) instead of label
                    // (String). Each .help(String) re-resolves the
                    // localization via Foundation's ulocimp every body
                    // eval — 3 profiles × 2 ViewThatFits branches ×
                    // ~60 Hz layout cascade was burning ~36 ms / sec
                    // on Foundation locale lookup alone, per the
                    // pan-while-connected sample. labelKey is a lazy
                    // wrapper SwiftUI resolves once per locale env.
                    .help(p.labelKey)
                    .tag(SpeedMode.preset(p))
            }
            Image(systemName: "speedometer")
                .help(LocalizedStringKey("Custom speed"))
                .tag(SpeedMode.custom)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 260)
        // LocalizedStringKey instead of String(localized:) so the
        // tooltip key is resolved lazily by SwiftUI's helper view
        // instead of by Foundation on every body eval. See the
        // matching note in the ForEach above for the perf rationale.
        .help(state.navigationActive
              ? LocalizedStringKey("Change travel mode mid-route. Speed updates immediately; route stays the same.")
              : LocalizedStringKey("Default travel mode for the next Navigate."))
    }

    @ViewBuilder
    private func pauseButton(udid: String) -> some View {
        if state.navigationPaused {
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
            .disabled(!state.navigationActive)
            .help(state.navigationActive
                  ? "Hold position; iPhone stays where it currently is."
                  : "No active navigation to pause.")
        }
    }

    /// Stop the current trip. Always calls `stopNavigation`. After
    /// stopping, if the user is in multi-stop mode with staged stops,
    /// offers to clear them (iPhone stays at last position either way).
    private func stopButton(udid: String) -> some View {
        Button(role: .destructive) {
            Task {
                await state.stopNavigation(udid: udid)
                if state.activeMovementMode == .multiStop,
                   !state.pendingStops.isEmpty {
                    showClearStopsAlert = true
                }
            }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .foregroundStyle(.red)
                .fontWeight(.semibold)
        }
        .tint(.red)
        .help(LocalizedStringKey("End navigation; iPhone stays at last simulated position."))
        .confirmationDialog(
            Text("Clear staged stops?",
                 comment: "BottomBar — stop+clear confirmation dialog title"),
            isPresented: $showClearStopsAlert,
            titleVisibility: .visible
        ) {
            Button("Clear stops", role: .destructive) {
                state.pendingStops = []
            }
            Button("Keep stops", role: .cancel) {}
        } message: {
            Text("Navigation stopped. Do you also want to remove the \(state.pendingStops.count) staged stops from the map?",
                 comment: "BottomBar — stop+clear confirmation message")
        }
    }

    /// Clears all simulation state (stops, routes, movement modes)
    /// without snapping the iPhone back to real GPS. Prompts first.
    private func clearButton(udid: String) -> some View {
        Button {
            showClearAllConfirm = true
        } label: {
            Label("Clear", systemImage: "xmark.circle")
        }
        .help(LocalizedStringKey("Clear all staged stops and movement state. iPhone stays at its current simulated position."))
        .confirmationDialog(
            String(localized: "Clear all stops and movement state?",
                   comment: "Clear-all confirmation title"),
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await state.clearAllState(udid: udid) }
            } label: {
                Text("Clear all",
                     comment: "Clear-all confirmation destructive button")
            }
            Button(role: .cancel) {} label: {
                Text("Cancel",
                     comment: "Clear-all confirmation cancel button")
            }
        } message: {
            Text("All staged stops, routes, and movement state will be removed. The iPhone stays at its current simulated position.",
                 comment: "Clear-all confirmation message")
        }
    }

    private var activeDevice: DeviceVM? {
        guard let udid = state.selectedUDID else { return nil }
        return state.devices.first(where: { $0.udid == udid })
    }
}

/// Isolated navigation-progress display. Has its own @Environment so
/// state.navigation (1 Hz) only re-renders this one block — not the
/// parent BottomBar body and not the ViewThatFits double-measure pass.
private struct NavigationProgressBlock: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let nav = state.navigation {
            // Fixed width prevents NSHostingView from re-negotiating
            // size with the parent NavigationSplitView on every 1 Hz
            // state.navigation update — the _FlexFrameLayout/
            // NavigationStackLayout recursion cascade (577 levels deep
            // in sample) is caused by .frame(maxWidth: .infinity) here.
            HStack(spacing: 10) {
                Image(systemName: etaIcon(nav: nav))
                    .foregroundStyle(nav.isPaused ? .orange : .green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(progressLabel(nav))
                            .font(.callout.monospacedDigit())
                        // Dwell-mode laps (DwellContext, multi-stop): use explicit
                        // fields since NavigationVM.laps is clamped to 1 in dwell
                        // mode (daemon runs one leg at a time). Regular laps (loop
                        // route or multi-stop without dwell): use progress-based fields.
                        let displayLaps = nav.dwellTotalLaps > 1 ? nav.dwellTotalLaps : nav.laps
                        let displayCurrentLap = nav.dwellTotalLaps > 1 ? nav.dwellCurrentLap : nav.currentLap
                        if displayLaps > 1 {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Lap \(displayCurrentLap) / \(displayLaps)")
                            }
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.lociSage.opacity(0.15), in: .capsule)
                            .foregroundStyle(Color.lociSage)
                        }
                    }
                    HStack(spacing: 6) {
                        ETAChip(etaSeconds: nav.etaSeconds, etaRefAt: nav.etaRefAt, isPaused: nav.isPaused)
                        Text("·").font(.callout).foregroundStyle(.tertiary)
                        ElapsedTimerChip(startedAt: nav.startedAt, isPaused: nav.isPaused, pausedAt: nav.pausedAt)
                        Text("·").font(.callout).foregroundStyle(.tertiary)
                        HStack(spacing: 3) {
                            Image(systemName: "speedometer").font(.caption)
                            Text(String(format: "%.0f km/h", nav.speedMps * 3.6))
                                .font(.callout.monospacedDigit())
                        }
                        .foregroundStyle(.secondary)
                    }
                    ProgressView(value: nav.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                }
            }
            .frame(width: 300, alignment: .leading)
        }
    }

    private func etaIcon(nav: NavigationVM) -> String {
        if nav.isPaused { return "pause.circle.fill" }
        if state.customSpeedMps != nil { return "speedometer" }
        return nav.profile.symbol
    }

    private func progressLabel(_ nav: NavigationVM) -> String {
        let traveled = nav.distanceM * nav.progress
        if nav.distanceM > 1_000 {
            return String(format: "%.2f / %.2f km", traveled / 1_000, nav.distanceM / 1_000)
        }
        return String(format: "%.0f / %.0f m", traveled, nav.distanceM)
    }
}

/// v1.11.2 T35: custom-speed text field shown in the bottom bar when
/// the Custom (speedometer) segment of the travel-mode picker is active.
///
/// Lives in its own struct so every keystroke into the TextField only
/// rerenders this small view — not the entire BottomBar (status pill,
/// nav progress, pause/stop, etc.). The parent bar shows/hides this
/// view based on `state.customSpeedMps != nil`.
///
/// On commit, hot-swaps an active navigation by re-applying the same
/// profile so the daemon's `apply_speed` path picks up the new mps.
/// The ✕ button clears the override and collapses this field; the user
/// can also click any preset segment in the travel-mode picker.
private struct CustomSpeedField: View {
    @Environment(AppState.self) private var state
    let udid: String

    @State private var draft: String = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("",
                      text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .controlSize(.regular)
                .multilineTextAlignment(.trailing)
                .onSubmit { commit() }
            Text("km/h",
                 comment: "BottomBar custom-speed field — units label")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                commit()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .disabled(parsedKmh == nil)
            .help(LocalizedStringKey("Apply this custom speed"))
            Button {
                clearOverride()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .help(LocalizedStringKey("Drop the custom speed and use the travel-mode preset"))
        }
        .onAppear { syncFromState() }
    }

    private var parsedKmh: Double? {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard let v = Double(trimmed), v > 0, v < 1_000 else { return nil }
        return v
    }

    private func syncFromState() {
        if let mps = state.customSpeedMps {
            draft = String(format: "%.1f", mps * 3.6)
        } else {
            draft = ""
        }
    }

    private func commit() {
        guard let kmh = parsedKmh else { return }
        state.customSpeedMps = kmh / 3.6
        if let nav = state.navigation {
            Task { await state.changeNavigationProfile(udid: udid, to: nav.profile) }
        }
    }

    private func clearOverride() {
        state.customSpeedMps = nil
        if let nav = state.navigation {
            Task { await state.changeNavigationProfile(udid: udid, to: nav.profile) }
        }
    }
}

/// Smooth ETA countdown chip.
///
/// The daemon sends `etaSeconds` at ~1 Hz with timing jitter — rendering
/// the raw value directly causes the ETA to jump by irregular amounts
/// (sometimes 1 s, sometimes 2 s, sometimes 0 s between updates).
///
/// Instead: record `etaRefAt` (the wall-clock when the daemon value was
/// received), then drive a `TimelineView(.periodic)` that subtracts
/// elapsed-since-ref from the reference ETA. Between daemon ticks the
/// counter counts down smoothly at exactly 1 s/s; when the next daemon
/// tick arrives with a fresh etaSeconds + etaRefAt, the chip snaps to
/// the authoritative value and resumes smooth countdown from there.
private struct ETAChip: View {
    let etaSeconds: Double
    let etaRefAt: Date
    let isPaused: Bool

    var body: some View {
        if isPaused {
            Text("ETA \(format(etaSeconds))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: etaRefAt, by: 1.0)) { ctx in
                let smooth = max(0.0, etaSeconds - ctx.date.timeIntervalSince(etaRefAt))
                Text("ETA \(format(smooth))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t >= 3600 { return String(format: "%d:%02d:%02d", t/3600, (t%3600)/60, t%60) }
        return String(format: "%d:%02d", t/60, t%60)
    }
}

private struct ElapsedTimerChip: View {
    let startedAt: Date
    let isPaused: Bool
    /// Snapshot of elapsed seconds captured at the moment pause was triggered,
    /// so the display freezes at the right value instead of the current wall time.
    let pausedAt: Date?

    var body: some View {
        if isPaused, let frozen = pausedAt {
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.caption)
                Text(elapsed(at: frozen))
                    .font(.callout.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: startedAt, by: 1.0)) { ctx in
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.caption)
                    Text(elapsed(at: ctx.date))
                        .font(.callout.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func elapsed(at now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(startedAt)))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
