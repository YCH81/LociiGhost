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

    /// Where in the route to begin playback.
    enum StartMode: Hashable { case beginning, resume, specific }
    @State private var startMode: StartMode = .beginning
    /// 1-based stop number bound to the Stepper while `startMode == .specific`.
    /// Converted to a 0-based index when passed to `runRoute`.
    @State private var specificStopNumber: Int = 1
    @State private var specificStopText: String = "1"

    /// True iff the Route has a saved snap progress AppState wrote on a
    /// previous Stop (and hasn't been cleared by a natural completion).
    /// The "Resume from last" radio is disabled when this is false so
    /// users can't pick a meaningless option.
    private var hasResumeProgress: Bool {
        route.lastPlayedStopIndex > 0
            && route.lastPlayedStopIndex < route.pointCount - 1
    }

    /// Translate the radio selection into the 0-based index `runRoute`
    /// uses to slice `route.points`. The Stepper's value is 1-based for
    /// human reading; we subtract one here so callers downstream don't
    /// have to. Resume falls back to `0` when no progress is saved so
    /// an accidental Resume + Start press still does the right thing
    /// rather than no-op.
    private var resolvedStartIndex: Int {
        switch startMode {
        case .beginning: return 0
        case .resume:    return hasResumeProgress ? route.lastPlayedStopIndex : 0
        case .specific:  return max(0, min(specificStopNumber - 1, route.pointCount - 1))
        }
    }

    /// Parse the typed value back into the Stepper. Called on Submit
    /// and again just before Start so a user who tabs out of the field
    /// without pressing Enter still has their typed value honoured.
    private func applySpecificStopText() {
        let trimmed = specificStopText.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed), n >= 1, n <= route.pointCount {
            specificStopNumber = n
        } else {
            specificStopText = "\(specificStopNumber)"
        }
    }

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

            // Start-point picker. Three exclusive choices, modelled as
            // a Picker rather than three Toggles so SwiftUI handles the
            // single-active-radio invariant without us reinventing it.
            // The Stepper for "specific" only shows when that option is
            // selected; same pattern as the Loop sub-row below.
            VStack(alignment: .leading, spacing: 4) {
                Text("Start from",
                     comment: "Start-route sheet — header above the start-point radio buttons")
                    .font(.callout.weight(.medium))
                Picker("", selection: $startMode) {
                    Text("Beginning",
                         comment: "Start-route sheet — start from the first stop")
                        .tag(StartMode.beginning)
                    if hasResumeProgress {
                        Text(String(
                            format: String(
                                localized: "Resume from last (#%lld)",
                                comment: "Start-route sheet — resume from where the previous playback was stopped, %lld is the saved 1-based stop number"),
                            route.lastPlayedStopIndex + 1
                        ))
                        .tag(StartMode.resume)
                    } else {
                        Text("Resume from last (no saved progress)",
                             comment: "Start-route sheet — resume option disabled because no progress is saved for this route")
                            .tag(StartMode.resume)
                    }
                    Text("Specific stop",
                         comment: "Start-route sheet — start from a stop the user picks below")
                        .tag(StartMode.specific)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if startMode == .specific {
                    HStack(spacing: 8) {
                        Text("Stop #",
                             comment: "Start-route sheet — label next to the specific-stop number field")
                            .font(.callout)
                        TextField("1", text: $specificStopText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onSubmit {
                                applySpecificStopText()
                            }
                        Stepper(value: $specificStopNumber,
                                in: 1...max(1, route.pointCount),
                                step: 1) {
                            Text("of \(route.pointCount)",
                                 comment: "Start-route sheet — \"of N\" suffix shown after the stop-number stepper, where N is total stop count")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.leading, 22)
                    .onChange(of: specificStopNumber) { _ in
                        // Keep the text field in sync when the user nudges
                        // the stepper — otherwise typing 47 then nudging
                        // would silently revert the visible value.
                        specificStopText = "\(specificStopNumber)"
                    }
                }
            }
            .onAppear {
                // Default to Resume when there's recoverable progress —
                // the most common reason to reopen this sheet is exactly
                // that. Plain Beginning otherwise.
                if hasResumeProgress { startMode = .resume }
                specificStopNumber = max(1, min(route.lastPlayedStopIndex + 1,
                                                route.pointCount))
                specificStopText = "\(specificStopNumber)"
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
                    applySpecificStopText()
                    let r = route
                    let lapCount = resolvedLapCount
                    let dwell = routeDwell
                    let dwellSecs = resolvedDwellSeconds
                    let startIdx = resolvedStartIndex
                    state.routePendingConfirm = nil
                    dismiss()
                    Task { @MainActor in
                        await state.runRoute(r, udid: udid, lapCount: lapCount,
                                             allowDwell: dwell,
                                             dwellSecondsForRoute: dwellSecs,
                                             startFromIndex: startIdx)
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
            // Pre-fill from the global setting so the user doesn't have to
            // re-enter what they already tuned in the Multi-Stop panel.
            // Saved-route playback still takes ONE number rather than a
            // range, so a range collapses to its midpoint here -- the
            // same number the ETA would have used anyway.
            routeDwellText = "\(Int(state.dwellRange.expectedSeconds.rounded()))"
        }
    }
}
