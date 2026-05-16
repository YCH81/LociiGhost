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

    private var resolvedLapCount: Int {
        guard loop else { return 1 }
        let trimmed = lapText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        if let n = Int(trimmed), n >= 2 { return n }
        return 0
    }

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
                    state.routePendingConfirm = nil
                    dismiss()
                    Task { @MainActor in
                        await state.runRoute(r, udid: udid, lapCount: lapCount)
                    }
                } label: {
                    Text("Start",
                         comment: "Confirm button on the start-route sheet")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }
}
