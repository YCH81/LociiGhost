import SwiftUI

/// Sheet shown when the user clicks a sidebar Route. Replaces the
/// earlier `.alert(presenting:)` so we can host a Toggle inside —
/// SwiftUI's standard alert only takes buttons + a plain `Text`
/// message, no inline controls.
///
/// v1.10.7 hotfix: the Loop checkbox gains a "Total laps" companion
/// field. Empty (or any non-Int input) means "until I press Stop";
/// a parseable Int ≥ 2 means "loop exactly N times total". The lap
/// count travels to `AppState.runRoute(lapCount:)` where lap
/// orchestration lives — each lap runs as a fresh single-trip
/// navigate, and `applyStateEvent`'s natural "idle" transition fires
/// the next teleport-back-to-start + navigate until the counter
/// drains. User Stop emits `stopped` (not `idle`), which clears
/// `loopContext` and breaks the cycle.
struct StartRouteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let route: Route

    @State private var loop: Bool = false
    /// Empty string = "until I press Stop" (sentinel `0` at the
    /// AppState boundary). "2"+ = fixed lap count. "1" or any other
    /// non-parseable input falls back to until-stop — looping with
    /// exactly one lap is meaningless and the toggle shouldn't be
    /// on in that case anyway.
    @State private var lapText: String = ""

    /// Per-execution dwell choice. Defaults to OFF so routes play
    /// back smoothly without stopping. User can enable from this
    /// sheet; the choice does NOT persist to the global dwellEnabled
    /// toggle (routes and multi-stop are independent settings).
    @State private var routeDwell: Bool = false
    @State private var routeDwellText: String = "5"

    private var resolvedLapCount: Int {
        guard loop else { return 1 }
        let trimmed = lapText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        if let n = Int(trimmed), n >= 2 { return n }
        return 0
    }

    private var resolvedDwellSeconds: Int {
        let trimmed = routeDwellText.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed), n >= 1 { return n }
        return 5
    }

    /// v1.11.2 bug #3: when a navigation / random walk / joystick is
    /// already running, surface a warning + relabel the confirm
    /// button so the user explicitly acknowledges the interruption.
    /// runRoute internally calls stopNavigation/stopRandomWalk first
    /// anyway (T20 fix), but doing it silently surprised users —
    /// this makes the stop-and-restart intent visible up front.
    private var hasActiveSession: Bool { state.anySessionActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath.fill")
                    .foregroundStyle(.tint)
                    .font(.title2)
                Text("Start route?",
                     comment: "Title of the start-route confirm sheet")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Text(String(
                format: String(
                    localized: "Teleport to the start of \"%1$@\" and navigate %2$lld points?",
                    comment: "Body of the start-route confirm sheet",
                ),
                route.name,
                route.pointCount,
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // v1.11.2 bug #3: visible warning when starting this
            // route will interrupt an in-flight simulation.
            if hasActiveSession {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    Text("Your current simulation will stop before this route starts.",
                         comment: "StartRouteSheet — warning shown when an active navigation / random walk / joystick will be interrupted")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 6))
            }

            Toggle(isOn: $loop) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loop the route",
                         comment: "Start-route sheet — auto-replay checkbox label")
                        .font(.callout)
                    Text("After reaching the last point, teleport back to the start and walk the route again.",
                         comment: "Start-route sheet — auto-replay checkbox explanation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            if loop {
                HStack(spacing: 8) {
                    Text("Total laps:",
                         comment: "Start-route sheet — lap-count field label")
                        .font(.callout)
                    TextField(
                        String(localized: "Until I press Stop",
                               comment: "Start-route sheet — lap-count placeholder for until-stop"),
                        text: $lapText
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    Text("(leave blank for until Stop)",
                         comment: "Start-route sheet — lap-count helper text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 22)
            }

            Toggle(isOn: $routeDwell) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pause at each waypoint",
                         comment: "Start-route sheet — per-waypoint dwell checkbox label")
                        .font(.callout)
                    Text("Stop and wait at each point along the route before continuing.",
                         comment: "Start-route sheet — per-waypoint dwell checkbox explanation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            if routeDwell {
                HStack(spacing: 8) {
                    Text("Pause seconds:",
                         comment: "Start-route sheet — dwell seconds field label")
                        .font(.callout)
                    TextField("5", text: $routeDwellText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("sec per waypoint",
                         comment: "Start-route sheet — dwell seconds unit label")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 22)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    state.routePendingConfirm = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    guard let udid = state.selectedUDID else {
                        state.routePendingConfirm = nil
                        dismiss()
                        return
                    }
                    let r = route
                    let lapCount = resolvedLapCount
                    let dwell = routeDwell
                    let dwellSecs = resolvedDwellSeconds
                    state.routePendingConfirm = nil
                    dismiss()
                    Task { @MainActor in
                        await state.runRoute(r, udid: udid, lapCount: lapCount,
                                             allowDwell: dwell,
                                             dwellSecondsForRoute: dwellSecs)
                    }
                } label: {
                    Text(hasActiveSession
                         ? String(localized: "Stop & start",
                                  comment: "Confirm button on the start-route sheet when a current simulation will be stopped first")
                         : String(localized: "Start",
                                  comment: "Confirm button on the start-route sheet"))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
        .onAppear {
            // Pre-fill dwell seconds from global setting so user doesn't need
            // to re-enter if they already tuned it in the Multi-Stop panel.
            routeDwellText = "\(state.dwellSeconds)"
        }
    }
}
