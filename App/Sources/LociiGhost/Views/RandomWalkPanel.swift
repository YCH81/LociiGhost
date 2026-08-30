import SwiftUI
import LociiGhostCore

/// Inline configuration + control surface for the random-walk mode.
/// Lives inside the sidebar's Movement Modes section; no sheet, no
/// modal. Speed comes from the shared SpeedPicker so it matches the
/// presets used by Navigate and the other modes.
struct RandomWalkPanel: View {
    @Environment(AppState.self) private var state

    @State private var radiusM: Double = 200
    /// Persisted across launches via @AppStorage — users who prefer
    /// OSRM-routed wandering shouldn't have to reselect every time
    /// they reopen the app.
    @AppStorage("randomWalk.routingEngine") private var routingEngine: String = "straight"

    /// v1.11.2: queues a pending change to path style or dwell while a
    /// random walk is actually running. The active walker snapshots
    /// these settings at start, so changing them mid-walk silently
    /// has no effect — confirm-and-restart is the only path that
    /// actually takes. Same pattern as MovementModesSection's
    /// mode-switch alert.
    @State private var pendingChange: PendingChange?

    private struct PendingChange: Identifiable {
        let id = UUID()
        let target: Target
        enum Target {
            case routingEngine(String)
            case dwellEnabled(Bool)
            case dwellSeconds(Int)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewBindings
                .frame(width: 0, height: 0)            // invisible plumbing
            // Center hint —————————————————————————————————————
            VStack(alignment: .leading, spacing: 2) {
                Text("Center")
                    .font(.caption.weight(.medium))
                Text(centerLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Radius slider ———————————————————————————————————
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Radius").font(.caption.weight(.medium))
                    Spacer()
                    Text("\(Int(radiusM)) m")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $radiusM, in: 30...2_000, step: 10)
            }

            // Path style picker ———————————————————————————————
            // Straight: cheapest, ignores roads/water/fences — the pin
            // teleports through buildings on a uniform-disc walk.
            // Map: every leg becomes an OSRM route-resolved polyline so
            // the meander follows real footpaths. v1.11.0.
            // v1.11.2: gated binding — if a walk is active, picking a
            // different style queues a confirmation rather than
            // silently changing it (the live walker snapshots this at
            // start so a change without restart is a no-op).
            VStack(alignment: .leading, spacing: 4) {
                Text("Path style").font(.caption.weight(.medium))
                Picker("Path style", selection: gatedRoutingEngine) {
                    Text(LocalizedStringKey("Straight line")).tag("straight")
                    Text(LocalizedStringKey("Map path (OSRM)")).tag("map")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }

            // Shared speed picker ——————————————————————————————
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed").font(.caption.weight(.medium))
                SpeedPicker()
            }

            // Per-target dwell — v1.11.2 inline (instead of
            // DwellModeRow) because both bindings are gated when a
            // walk is active, mirroring the path-style gating above.
            // The walker snapshots dwell at start, so changing it
            // live requires a stop+restart to take effect.
            HStack(spacing: 8) {
                Toggle(isOn: gatedDwellEnabled) {
                    Text("Dwell at each stop",
                         comment: "RandomWalkPanel — toggle pausing N seconds at each random walk target")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                Spacer(minLength: 6)
                if state.dwellEnabled {
                    Stepper(
                        value: gatedDwellSeconds,
                        in: 1...3600,
                        step: 5,
                    ) {
                        Text("\(state.dwellSeconds) s",
                             comment: "Random walk dwell duration stepper label, in seconds")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
            }

            // Action ——————————————————————————————————————————
            actionRow
        }
        .alert(
            String(localized: "Stop random walk to change this?",
                   comment: "RandomWalkPanel — confirm before stopping & restarting walk to apply a setting change"),
            isPresented: Binding(
                get: { pendingChange != nil },
                set: { if !$0 { pendingChange = nil } },
            ),
            presenting: pendingChange,
        ) { pending in
            Button(role: .cancel) {
                pendingChange = nil
            } label: {
                Text("Keep walking",
                     comment: "RandomWalkPanel alert — cancel button, keep the current walk running")
            }
            Button(role: .destructive) {
                let target = pending.target
                pendingChange = nil
                applyAfterRestart(target)
            } label: {
                Text("Stop & apply",
                     comment: "RandomWalkPanel alert — destructive button, stops the walk, applies the change, restarts the walk")
            }
        } message: { _ in
            Text("Changing this setting needs the current walk to stop. We'll restart it immediately with the new value.",
                 comment: "RandomWalkPanel alert message — explains the stop-and-restart loop")
        }
    }

    // MARK: -

    /// Side-effect-only view: keeps the AppState preview fields in sync
    /// with the panel's local state, so the map can render a circle
    /// while the user is fiddling with the radius slider.
    private var previewBindings: some View {
        Color.clear
            .onAppear { syncPreviewToMap() }
            .onDisappear { clearPreviewOnMap() }
            .onChange(of: radiusM) { _, _ in syncPreviewToMap() }
            // v1.11.2 perf: guard against 1 Hz re-renders.
            // simulatedLocation updates every position event; writing
            // randomWalkPreviewCenter on every tick cascades into
            // MapContainerView's observation loop. Gate so we only
            // sync when the panel is in preview state (walk not running).
            .onChange(of: state.simulatedLocation) { _, _ in
                guard !state.randomWalkActive else { return }
                syncPreviewToMap()
            }
            // macLocation fires at CoreLocation's own cadence (~1 Hz).
            // Same guard — only sync when idle.
            .onChange(of: state.macLocation.coordinate?.latitude ?? 0) { _, _ in
                guard !state.randomWalkActive else { return }
                syncPreviewToMap()
            }
    }

    private func syncPreviewToMap() {
        // While a real walker is running we hand the visual story over
        // to the live "iPhone (simulated)" pin and the existing route
        // overlays — keep the preview disc out of the way.
        if state.randomWalkActive {
            clearPreviewOnMap()
            return
        }
        state.randomWalkPreviewCenter = defaultCenter
        state.randomWalkPreviewRadiusM = radiusM
    }

    private func clearPreviewOnMap() {
        state.randomWalkPreviewCenter = nil
        state.randomWalkPreviewRadiusM = nil
    }

    private var defaultCenter: Coordinate? {
        if let sim = state.simulatedLocation { return sim }
        if let mac = state.macLocation.coordinate {
            return Coordinate(lat: mac.latitude, lng: mac.longitude)
        }
        return nil
    }

    private var centerLabel: String {
        guard let c = defaultCenter else {
            return "Waiting for location…"
        }
        let source = state.simulatedLocation != nil
            ? "iPhone position"
            : "Mac location"
        return String(format: "%.5f, %.5f · %@", c.lat, c.lng, source)
    }

    @ViewBuilder
    private var actionRow: some View {
        if state.randomWalkActive {
            HStack(spacing: 8) {
                Label("Walking randomly", systemImage: "shuffle.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button(role: .destructive) {
                    if let udid = state.selectedUDID {
                        Task { await state.stopRandomWalk(udid: udid) }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.small)
            }
        } else {
            Button {
                Task { await start() }
            } label: {
                Label("Start Random Walk", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
        }
    }

    private var canStart: Bool {
        guard defaultCenter != nil else { return false }
        guard let udid = state.selectedUDID,
              state.devices.first(where: { $0.udid == udid })?.connected == true
        else { return false }
        return true
    }

    private func start() async {
        guard let udid = state.selectedUDID, let center = defaultCenter else { return }
        let speed = state.customSpeedMps ?? state.travelProfile.defaultSpeedMps
        // Original RandomWalker takes a min/max band so successive legs
        // vary; with a single canonical speed we use a tight ±15% window
        // which still feels organic without exposing a separate slider.
        let minMps = max(0.1, speed * 0.85)
        let maxMps = speed * 1.15
        await state.startRandomWalk(
            udid: udid,
            center: center,
            radiusM: radiusM,
            minSpeedMps: minMps,
            maxSpeedMps: maxMps,
            routingEngine: routingEngine
        )
    }

    // MARK: - v1.11.2 gated bindings

    /// Path-style picker binding that queues a confirmation rather
    /// than writing the new value through, whenever a walk is
    /// already running. No-op for inactive walks (straight pass-thru).
    private var gatedRoutingEngine: Binding<String> {
        Binding(
            get: { routingEngine },
            set: { new in
                if state.randomWalkActive && new != routingEngine {
                    pendingChange = PendingChange(target: .routingEngine(new))
                } else {
                    routingEngine = new
                }
            }
        )
    }

    private var gatedDwellEnabled: Binding<Bool> {
        Binding(
            get: { state.dwellEnabled },
            set: { new in
                if state.randomWalkActive && new != state.dwellEnabled {
                    pendingChange = PendingChange(target: .dwellEnabled(new))
                } else {
                    state.dwellEnabled = new
                }
            }
        )
    }

    private var gatedDwellSeconds: Binding<Int> {
        Binding(
            get: { state.dwellSeconds },
            set: { new in
                if state.randomWalkActive && new != state.dwellSeconds {
                    pendingChange = PendingChange(target: .dwellSeconds(new))
                } else {
                    state.dwellSeconds = new
                }
            }
        )
    }

    /// Stop the active walk → write the queued change to the underlying
    /// storage → restart with the new value. Async so the stop call
    /// completes before we apply + restart (otherwise the restart can
    /// race with the daemon's stop-and-cleanup path).
    private func applyAfterRestart(_ target: PendingChange.Target) {
        Task {
            if let udid = state.selectedUDID, state.randomWalkActive {
                await state.stopRandomWalk(udid: udid)
            }
            await MainActor.run {
                switch target {
                case .routingEngine(let v): routingEngine = v
                case .dwellEnabled(let v): state.dwellEnabled = v
                case .dwellSeconds(let v): state.dwellSeconds = v
                }
            }
            await start()
        }
    }
}
