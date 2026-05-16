import SwiftUI

/// Sheet shown when the user clicks a sidebar Route. Replaces the
/// earlier `.alert(presenting:)` so we can host a Toggle inside —
/// SwiftUI's standard alert only takes buttons + a plain `Text`
/// message, no inline controls.
///
/// The "Loop until I stop" checkbox is the v1.10.7 addition. When
/// ticked, `runRoute(loop: true)` raises `routeLaps` to 9 999 for
/// the duration of the navigate-RPC call, which the daemon then
/// uses as its session lap count — effectively unlimited replays
/// until the user hits Stop.
struct StartRouteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let route: Route

    @State private var loop: Bool = false

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
                    Text("Loop until I stop",
                         comment: "Start-route sheet — auto-replay checkbox label")
                        .font(.callout)
                    Text("After the iPhone reaches the last point, automatically restart from the beginning and keep going. Hit Stop to end.",
                         comment: "Start-route sheet — auto-replay checkbox explanation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

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
                    let loopFlag = loop
                    state.routePendingConfirm = nil
                    dismiss()
                    Task { @MainActor in
                        await state.runRoute(r, udid: udid, loop: loopFlag)
                    }
                } label: {
                    Text("Start",
                         comment: "Confirm button on the start-route sheet")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 440)
    }
}
