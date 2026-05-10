import SwiftUI

/// Inline configuration + control surface for the random-walk mode.
/// Lives inside the sidebar's Movement Modes section; no sheet, no
/// modal. Speed comes from the shared SpeedPicker so it matches the
/// presets used by Navigate and the other modes.
struct RandomWalkPanel: View {
    @Environment(AppState.self) private var state

    @State private var radiusM: Double = 200

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

            // Shared speed picker ——————————————————————————————
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed").font(.caption.weight(.medium))
                SpeedPicker()
            }

            // Action ——————————————————————————————————————————
            actionRow
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
            .onChange(of: state.simulatedLocation) { _, _ in syncPreviewToMap() }
            .onChange(of: state.macLocation.coordinate?.latitude ?? 0) { _, _ in syncPreviewToMap() }
    }

    private func syncPreviewToMap() {
        // While a real walker is running we hand the visual story over
        // to the live "iPhone (simulated)" pin and the existing route
        // overlays — keep the preview disc out of the way.
        if state.randomWalk != nil {
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
        if state.randomWalk != nil {
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
            maxSpeedMps: maxMps
        )
    }
}
