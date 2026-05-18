import SwiftUI

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

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.below.rectangle")
                if stops.count > 1 {
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

            Divider()

            // Travel mode + speed (shared with sidebar mode panels)
            VStack(alignment: .leading, spacing: 6) {
                Text("Travel mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            // Actions
            HStack(spacing: 8) {
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
                    state.pendingStops = []
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
    private var isLockedDuringNavigation: Bool {
        state.navigation != nil
    }

    /// What speed will be sent to `location.navigate`.
    private var chosenSpeed: Double {
        state.customSpeedMps ?? state.travelProfile.defaultSpeedMps
    }

    private var speedLabel: String {
        let kmh = chosenSpeed * 3.6
        return String(format: "%.1f km/h (%.1f m/s)", kmh, chosenSpeed)
    }
}
