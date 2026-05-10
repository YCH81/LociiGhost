import SwiftUI

/// Walks the user through enabling Developer Mode on the iPhone.
///
/// Triggering the daemon's `device.reveal_developer_mode` is the easy half:
/// it just makes the toggle appear in iPhone Settings. The real workflow
/// happens on the phone, so this sheet exists primarily to spell out the
/// sequence in plain language and leave it on screen until the user has
/// actually finished.
struct DeveloperModeSheet: View {
    let device: DeviceVM
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var isRevealing = false
    @State private var nextSteps: [String] = []
    @State private var revealError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "hammer.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Developer Mode")
                        .font(.title3.weight(.semibold))
                    Text(device.name + " · iOS " + device.iosVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("iOS 17+ requires Developer Mode for any tool that injects a simulated GPS coordinate over the RSD tunnel. The toggle is hidden by default; LocWarp can ask iOS to surface it for you.")
                .font(.callout)

            if !nextSteps.isEmpty {
                stepList
            } else {
                placeholderSteps
            }

            if let err = revealError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.red.opacity(0.1), in: .rect(cornerRadius: 6))
            }

            Spacer(minLength: 4)

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button {
                    Task { await reveal() }
                } label: {
                    if isRevealing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(nextSteps.isEmpty ? "Reveal Toggle on iPhone" : "Done")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRevealing)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: -

    @ViewBuilder
    private var placeholderSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow(1, "Click the button below to ask iOS to show the toggle.")
            stepRow(2, "On the iPhone: Settings → Privacy & Security → Developer Mode → ON.")
            stepRow(3, "Restart the iPhone when prompted, then confirm Turn On.")
            stepRow(4, "Re-plug USB and click Connect again.")
        }
    }

    @ViewBuilder
    private var stepList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(nextSteps.enumerated()), id: \.offset) { idx, step in
                stepRow(idx + 1, step)
            }
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }

    private func reveal() async {
        if !nextSteps.isEmpty {
            dismiss()
            return
        }
        isRevealing = true
        revealError = nil
        let steps = await state.revealDeveloperMode(udid: device.udid)
        isRevealing = false
        if steps.isEmpty {
            revealError = state.lastError ?? "Could not reach the device. Make sure it's plugged in and trusted."
        } else {
            nextSteps = steps
        }
    }
}
