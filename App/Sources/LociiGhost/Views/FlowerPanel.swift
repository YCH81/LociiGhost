import SwiftUI
import LociiGhostCore

/// Flower mode: walk a small ring around each staged waypoint, lap
/// after lap, for as many rounds as the user asks.
///
/// Waypoints are `pendingStops` — the same list Multi-stop uses, and
/// the same map clicks fill it. A second staging list for the same
/// idea would mean the user building their route twice depending on
/// which mode they happened to open first.
struct FlowerPanel: View {
    @Environment(AppState.self) private var state

    /// The daemon's answer for the current settings. Nil until the
    /// first estimate lands, or when there is nothing to estimate.
    @State private var estimate: FlowerEstimate?
    @State private var estimateTask: Task<Void, Never>?

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            waypointSummary

            LabeledContent {
                Text("\(Int(state.flowerConfig.radiusM)) m")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } label: {
                Text("Ring radius").font(.caption.weight(.medium))
            }
            Slider(value: $state.flowerConfig.radiusM, in: 5...300, step: 5)

            HStack(spacing: 10) {
                stepper(
                    title: LocalizedStringKey("Stops per lap"),
                    value: Binding(get: { Double(state.flowerConfig.segments) },
                                   set: { state.flowerConfig.segments = Int($0) }),
                    range: Self.segmentSliderRange,
                    step: 1,
                    format: { String(Int($0)) })
                stepper(
                    title: LocalizedStringKey("Laps per point"),
                    value: $state.flowerConfig.laps,
                    range: 0.5...20,
                    step: FlowerConfig.lapStep,
                    format: { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) })
            }

            HStack(spacing: 10) {
                stepper(
                    title: LocalizedStringKey("Rounds"),
                    value: Binding(get: { Double(state.flowerConfig.rounds) },
                                   set: { state.flowerConfig.rounds = Int($0) }),
                    range: 1...99,
                    step: 1,
                    format: { String(Int($0)) })
                stepper(
                    title: LocalizedStringKey("Pause at each stop"),
                    value: $state.flowerConfig.dwellSeconds,
                    range: 0...120,
                    step: 1,
                    format: { "\(Int($0)) s" })
            }

            HStack(spacing: 10) {
                stepper(
                    title: LocalizedStringKey("Wait on arrival"),
                    value: $state.flowerConfig.waitBeforeSeconds,
                    range: 0...600,
                    step: 5,
                    format: { "\(Int($0)) s" })
                stepper(
                    title: LocalizedStringKey("Wait before leaving"),
                    value: $state.flowerConfig.waitAfterSeconds,
                    range: 0...600,
                    step: 5,
                    format: { "\(Int($0)) s" })
            }

            Toggle(isOn: $state.flowerConfig.teleportBetween) {
                Text("Teleport between waypoints",
                     comment: "FlowerPanel — jump instead of walking between rings")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Text("The ring itself is always walked. A ring of teleports is the one thing that looks nothing like a person.",
                 comment: "FlowerPanel — why the teleport toggle only covers the hops between waypoints")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            estimateLine
            actionRow
        }
        .task { await refreshEstimate() }
        .onChange(of: state.flowerConfig) { _, _ in scheduleEstimate() }
        .onChange(of: state.pendingStops) { _, _ in scheduleEstimate() }
        .onDisappear { estimateTask?.cancel() }
    }

    // MARK: - Pieces

    private var waypoints: [Coordinate] { state.pendingStops }

    @ViewBuilder
    private var waypointSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Waypoints").font(.caption.weight(.medium))
            if waypoints.isEmpty {
                Text("Click the map to add the points to orbit.",
                     comment: "FlowerPanel — empty waypoint list hint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: String(localized: "%lld staged · same list as Multi-stop",
                                           comment: "FlowerPanel — waypoint count"),
                            waypoints.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var estimateLine: some View {
        if let estimate, estimate.points > 0 {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(
                    format: String(localized: "%lld stops each · about %@ in total",
                                   comment: "FlowerPanel — live estimate line"),
                    estimate.verticesPerPoint,
                    Self.durationLabel(estimate.seconds)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if let run = state.flowerRun {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: run.progress)
                    .controlSize(.small)
                Text(String(
                    format: String(localized: "Round %lld of %lld · point %lld of %lld · %@ left",
                                   comment: "FlowerPanel — progress while a run is going"),
                    run.roundIndex + 1, run.rounds,
                    run.pointIndex + 1, run.points,
                    Self.durationLabel(run.etaSeconds)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label("Orbiting", systemImage: "camera.macro")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    Button(role: .destructive) {
                        if let udid = state.selectedUDID {
                            Task { await state.stopFlower(udid: udid) }
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                }
            }
        } else {
            Button {
                if let udid = state.selectedUDID {
                    Task { await state.startFlower(udid: udid, points: waypoints) }
                }
            } label: {
                Label("Start Flower Mode", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
        }
    }

    private var canStart: Bool {
        guard !waypoints.isEmpty, let udid = state.selectedUDID else { return false }
        return state.devices.first { $0.udid == udid }?.connected == true
    }

    private func stepper(
        title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String,
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.medium))
            Stepper(value: value, in: range, step: step) {
                Text(format(value.wrappedValue))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Estimate

    /// Ask the daemon, but not on every stepper click.
    ///
    /// The estimate is a round trip, and holding a stepper's arrow
    /// fires several changes a second. A short debounce keeps the
    /// readout feeling live without a request per repeat.
    private func scheduleEstimate() {
        estimateTask?.cancel()
        estimateTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await refreshEstimate()
        }
    }

    @MainActor
    private func refreshEstimate() async {
        guard !waypoints.isEmpty else {
            estimate = nil
            return
        }
        estimate = await state.estimateFlower(points: waypoints,
                                              from: state.simulatedLocation)
    }

    /// The daemon's own segment bounds, as a Double range for the
    /// stepper.
    static let segmentSliderRange =
        Double(FlowerConfig.segmentRange.lowerBound)...Double(FlowerConfig.segmentRange.upperBound)

    /// "1 h 12 m" / "45 s". Rounded, because a projected total that
    /// claims seconds it cannot know reads as precision the number
    /// doesn't have.
    static func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
