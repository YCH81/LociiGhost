import SwiftUI
import LociiGhostCore

/// Floating panel shown over the top-left of the map when the user has
/// at least one staged stop. Two actions:
///
/// * **Teleport** — instant jump to the *last* stop (multi-stop teleport
///   doesn't make sense; you can only end up at one spot).
/// * **Navigate** — plan a road route through every stop in order and
///   walk the iPhone along it at the chosen profile's speed.
///
/// "Current" (the route's origin) is whichever location our state
/// machine considers authoritative right now — the simulated location
/// if we're already pretending to be somewhere, else the Mac's
/// CoreLocation fix.
struct ControlPanel: View {
    let udid: String
    /// Click of the X button — caller hides the panel without
    /// touching pendingStops. The sidebar list survives, and a small
    /// "Show controls" button replaces the panel until the user
    /// re-opens it. The Clear-all-stops action lives in the sidebar's
    /// Multi-Stop panel; X here is purely a minimise gesture.
    let onDismiss: () -> Void

    @Environment(AppState.self) private var state

    /// Typed km/h for flower mode's custom speed, and whether the
    /// user has actually chosen the Custom segment. The flag has to
    /// be sticky: the config stores only a speed, so tapping Custom
    /// while sitting on a preset would otherwise be undone the
    /// instant the picker re-derived its selection from that
    /// unchanged number.
    @State private var flowerCustomInput: String = ""
    @State private var flowerCustomSelected: Bool = false

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.below.rectangle")
                if isFlower {
                    // Same word the sidebar's flower panel uses: these
                    // are centres to orbit, not stops to pass through.
                    Text("Waypoints",
                         comment: "Header — staged waypoint list in flower mode")
                        .font(.headline)
                } else if stops.count > 1 {
                    Text("\(stops.count) stops",
                         comment: "Header — number of staged multi-stop targets")
                        .font(.headline)
                } else {
                    Text("Target",
                         comment: "Header for a single-target route panel")
                        .font(.headline)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey("Hide this panel — stops stay in the sidebar; click the floating chip on the map to bring it back"))
            }

            stopsList

            // v1.11.2 round 15: Smart sort back on the on-map panel
            // too — `.frame(maxWidth: .infinity)` removed since
            // that was the layout-spin trigger in the round-1 add.
            // Plain button + leading-aligned HStack; no flex frame,
            // no NSHostingView size renegotiation.
            if stops.count >= 3 {
                HStack(spacing: 0) {
                    Button {
                        smartSortStops()
                    } label: {
                        Label {
                            Text("Smart sort",
                                 comment: "ControlPanel — reorder staged stops by minimum total path distance")
                        } icon: {
                            Image(systemName: "wand.and.stars")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(LocalizedStringKey("Reorder stops by minimum total path distance — Stop 1 stays the start"))
                    Spacer(minLength: 0)
                }
            }

            Divider()

            // Travel mode + speed (shared with sidebar mode panels)
            VStack(alignment: .leading, spacing: 6) {
                Text("Travel mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isFlower {
                    flowerTravelPicker
                } else {
                SpeedPicker()
                    .disabled(state.useStraightLine)

                HStack(spacing: 8) {
                    Image(systemName: state.routeLaps > 1
                          ? "arrow.triangle.2.circlepath"
                          : "arrow.right")
                        .foregroundStyle(state.routeLaps > 1 ? Color.lociSage : Color.secondary)
                    Text("Laps")
                        .font(.caption)
                    Stepper(value: $state.routeLaps, in: 1...99) {
                        Text("\(state.routeLaps)")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 26, alignment: .trailing)
                    }
                    .controlSize(.small)
                    .labelsHidden()
                    if state.routeLaps > 1 {
                        Text("\(state.routeLaps)× looped",
                             comment: "Lap count badge — N times around")
                            .font(.caption2)
                            .foregroundStyle(Color.lociSage)
                    } else {
                        Text("single trip",
                             comment: "Lap count badge when laps == 1")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .disabled(isLockedDuringNavigation)

                // v1.11.0: dwell-at-each-stop, also surfaced here so
                // the user can flip it on while staring at the on-map
                // ControlPanel without having to dig back to the
                // sidebar Multi-Stop panel.
                DwellModeRow()
                    .disabled(isLockedDuringNavigation)

                Toggle(isOn: $state.useStraightLine) {
                    HStack(spacing: 6) {
                        Image(systemName: state.useStraightLine
                              ? "arrow.up.right.circle.fill"
                              : "arrow.up.right.circle")
                            .foregroundStyle(state.useStraightLine ? Color.lociSage : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Group {
                                if state.useStraightLine {
                                    Text("Straight line — ON",
                                         comment: "Toggle label when straight-line route is on")
                                } else {
                                    Text("Straight line (skip roads)",
                                         comment: "Toggle label inviting straight-line mode (off state)")
                                }
                            }
                                .font(.caption.weight(state.useStraightLine ? .semibold : .regular))
                            if isLockedDuringNavigation {
                                Text("Locked while navigating. Stop first to switch.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else if state.useStraightLine {
                                Text("Path is a great-circle line, no street routing.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(8)
                .background(
                    state.useStraightLine
                    ? AnyShapeStyle(Color.lociSage.opacity(0.12))
                    : AnyShapeStyle(Color.secondary.opacity(0.06)),
                    in: .rect(cornerRadius: 6)
                )
                .disabled(isLockedDuringNavigation)
                .help(isLockedDuringNavigation
                      ? "Cannot change routing mode while a trip is running. Stop first."
                      : "Walk a great-circle line straight through every stop, ignoring streets. Applies on the next Navigate click.")
                }
            }

            // Actions
            HStack(spacing: 8) {
                if isFlower {
                    // The staged points mean something different here:
                    // Navigate would drive straight through them and
                    // never orbit anything.
                    Button {
                        Task { await state.startFlower(udid: udid, points: stops) }
                    } label: {
                        Label("Start Flower Mode", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(connectedDevice == nil || stops.isEmpty
                              || state.flowerRun != nil)
                    .help("Orbit every staged waypoint, lap after lap")
                } else {
                Button {
                    Task {
                        await state.navigate(udid: udid,
                                             through: stops,
                                             profile: state.travelProfile,
                                             speed: chosenSpeed)
                    }
                } label: {
                    Label("Navigate", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(connectedDevice == nil || stops.isEmpty)
                .help(stops.count > 1
                      ? "Plan a route through all \(stops.count) stops in order"
                      : "Plan a route and animate the iPhone along it")
                }

                if stops.count == 1, let only = stops.first {
                    Button {
                        Task { await state.teleport(udid: udid, lat: only.lat, lng: only.lng) }
                    } label: {
                        Label("Teleport", systemImage: "wand.and.stars")
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help("Jump instantly without simulating travel")
                    .disabled(connectedDevice == nil)
                }

                Button("Cancel") {
                    Task {
                        if let udid = state.selectedUDID {
                            if state.flowerActive {
                                await state.stopFlower(udid: udid)
                            } else if state.navigationActive {
                                await state.stopNavigation(udid: udid)
                            }
                        }
                        state.pendingStops = []
                        state.schedulePreviewRefresh()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }

            if connectedDevice == nil {
                Text("Connect a device first.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if stops.count > 1 {
                Text("Tip: click the map again to add another stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .frame(maxWidth: 320, alignment: .leading)
    }

    // MARK: -

    private var stops: [Coordinate] { state.pendingStops }

    private var isFlower: Bool { state.activeMovementMode == .flower }

    /// Flower mode walks or cycles its rings — nothing else. Driving a
    /// 70 m circle is not a thing a person does, so the third segment
    /// is gone rather than merely discouraged.
    ///
    /// It writes `flowerConfig.speedMps` directly. The daemon reads
    /// that, never `travelProfile`, so binding this to the multi-stop
    /// picker would show a speed that the run then ignored.
    private var flowerTravelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { flowerSpeedChoice },
                set: { choice in
                    switch choice {
                    case .custom:
                        flowerCustomSelected = true
                        if flowerCustomInput.isEmpty {
                            flowerCustomInput = String(
                                format: "%.1f", state.flowerConfig.speedMps * 3.6)
                        }
                    case .walking:
                        flowerCustomSelected = false
                        state.flowerConfig.speedMps = TravelProfile.walking.defaultSpeedMps
                    case .cycling:
                        flowerCustomSelected = false
                        state.flowerConfig.speedMps = TravelProfile.cycling.defaultSpeedMps
                    }
                }
            )) {
                Label(TravelProfile.walking.labelKey,
                      systemImage: TravelProfile.walking.symbol)
                    .tag(FlowerSpeedChoice.walking)
                Label(TravelProfile.cycling.labelKey,
                      systemImage: TravelProfile.cycling.symbol)
                    .tag(FlowerSpeedChoice.cycling)
                Text("Custom",
                     comment: "Label for the free-form speed entry next to the travel presets")
                    .tag(FlowerSpeedChoice.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if flowerSpeedChoice == .custom {
                HStack(spacing: 6) {
                    TextField("km/h", text: $flowerCustomInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit { applyFlowerCustomSpeed() }
                    Button("Use") { applyFlowerCustomSpeed() }
                        .controlSize(.small)
                        .disabled(parsedFlowerCustomKmh == nil)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .foregroundStyle(.secondary)
                Text("Speed: \(String(format: "%.1f", state.flowerConfig.speedMps * 3.6)) km/h",
                     comment: "Effective speed readout under the SpeedPicker; first %@ is the km/h value")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            // Only a hand-typed speed earns the warning. The cycling
            // preset is 19.8 km/h and is exempt by design: it is a
            // speed the user picked off a list we offered, not one
            // they overshot into.
            if flowerSpeedWarnsAboutPlanting {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("Over 15 km/h the flower may fail to plant.",
                         comment: "Flower mode — caution under a hand-typed speed above 15 km/h")
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
            }
        }
        .disabled(state.flowerRun != nil)
    }

    private enum FlowerSpeedChoice: Hashable { case walking, cycling, custom }

    /// Which segment lights up. Derived from the stored speed so a
    /// value set anywhere else still shows correctly, with the sticky
    /// flag winning so Custom stays selected while the user types.
    private var flowerSpeedChoice: FlowerSpeedChoice {
        if flowerCustomSelected { return .custom }
        let speed = state.flowerConfig.speedMps
        if abs(speed - TravelProfile.walking.defaultSpeedMps) < 0.001 { return .walking }
        if abs(speed - TravelProfile.cycling.defaultSpeedMps) < 0.001 { return .cycling }
        return .custom
    }

    /// 15 km/h is roughly where a "walked" ring stops looking walked.
    private static let flowerPlantingSpeedLimitKmh = 15.0

    private var flowerSpeedWarnsAboutPlanting: Bool {
        flowerSpeedChoice == .custom
            && state.flowerConfig.speedMps * 3.6 > Self.flowerPlantingSpeedLimitKmh
    }

    private var parsedFlowerCustomKmh: Double? {
        let trimmed = flowerCustomInput.trimmingCharacters(in: .whitespaces)
        guard let v = Double(trimmed), v > 0, v < 1_000 else { return nil }
        return v
    }

    /// Applies but never clamps: the ceiling is advice, and silently
    /// rewriting a number the user typed is worse than letting them
    /// run a ring that may not plant.
    private func applyFlowerCustomSpeed() {
        guard let kmh = parsedFlowerCustomKmh else { return }
        flowerCustomSelected = true
        state.flowerConfig.speedMps = kmh / 3.6
    }

    private static let flowerProfiles: [TravelProfile] = [.walking, .cycling]

    private var stopsList: some View {
        // Cap the on-map control's stops list at ~280pt height so a
        // long bulk-paste (50+ stops) doesn't stretch the ControlPanel
        // off the bottom of the map with no way to scroll. ScrollView
        // wraps the rows; the surrounding panel stays at a sane size.
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(stops.enumerated()), id: \.offset) { idx, stop in
                    HStack(alignment: .center, spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tint)
                            .frame(width: 18, alignment: .trailing)
                        Text(String(format: "%.5f, %.5f", stop.lat, stop.lng))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            state.pendingStops.remove(at: idx)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this stop")
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private var connectedDevice: DeviceVM? {
        state.devices.first(where: { $0.udid == udid && $0.connected })
    }

    /// Straight-line vs road-routing is decided up front because the
    /// daemon's navigator gets the final polyline at start time. Mid-
    /// route flipping would need a re-route, which we don't support.
    private var isLockedDuringNavigation: Bool { state.navigationActive }

    /// What speed will be sent to `location.navigate`.
    private var chosenSpeed: Double {
        state.customSpeedMps ?? state.travelProfile.defaultSpeedMps
    }

    private var speedLabel: String {
        let kmh = chosenSpeed * 3.6
        return String(format: "%.1f km/h (%.1f m/s)", kmh, chosenSpeed)
    }

    /// v1.11.2: smart sort wraps `StopOrdering.smartSorted` and
    /// no-ops if the result is unchanged (no SwiftData write
    /// pressure on a redundant assignment).
    private func smartSortStops() {
        let current = state.pendingStops
        guard current.count >= 3 else { return }
        // v1.15.2 audit (P4): StopOrdering is pure and now bounded,
        // but it isn't cheap — a bulk-pasted GPX can drop hundreds of
        // stops in here, and running it inline from the button action
        // froze the window with no progress and no way out. It is
        // documented safe on any thread, so it goes off the main actor
        // and only the assignment comes back.
        let appState = state
        Task { @MainActor in
            let sorted = await Task.detached(priority: .userInitiated) {
                StopOrdering.smartSorted(current)
            }.value
            if sorted != appState.pendingStops {
                appState.pendingStops = sorted
            }
        }
    }
}
