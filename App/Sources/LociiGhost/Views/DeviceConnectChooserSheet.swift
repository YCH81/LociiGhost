import SwiftUI

/// Double-click a phone: how should we reach it?
///
/// The two transports are not interchangeable, so this asks rather
/// than guessing. USB is the reliable bring-up path for any iOS
/// version; WiFi needs a pair record and a remote-pairing handshake
/// that has to be redone whenever the iPhone reboots — picking it
/// hands straight over to the candidate picker, because the address
/// is the part that actually needs deciding.
struct DeviceConnectChooserSheet: View {
    let device: DeviceVM
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.title3.weight(.semibold))
                    Text("How should LociiGhost reach this iPhone?",
                         comment: "Connect chooser — subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if device.connected {
                Text("Already connected. Disconnect first to switch transport.",
                     comment: "Connect chooser — shown when the device is already connected")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            choice(
                symbol: "cable.connector",
                title: "Connect via USB",
                detail: "Works on any iOS version and survives a reboot. Needs the cable plugged in.",
                enabled: !device.connected && device.supportsUSB,
                disabledHint: device.supportsUSB ? nil : "Plug in the USB cable first.",
            ) {
                Task { await state.connect(udid: device.udid, preferWiFi: false) }
                dismiss()
            }

            choice(
                symbol: "wifi",
                title: "Connect via WiFi…",
                detail: "Opens the address picker so you can choose a discovered iPhone or type its IP.",
                enabled: !device.connected && device.supportsWiFi,
                disabledHint: device.supportsWiFi ? nil : "Run Pair for WiFi once with the cable plugged in.",
            ) {
                // Dismiss first: the candidate picker is itself a
                // presentation, and stacking it on a sheet that is
                // still closing drops it on some macOS versions.
                dismiss()
                state.openWiFiConnectFlow(udid: device.udid)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private func choice(symbol: String,
                        title: LocalizedStringKey,
                        detail: LocalizedStringKey,
                        enabled: Bool,
                        disabledHint: LocalizedStringKey?,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(enabled ? detail : (disabledHint ?? detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(enabled ? 0.08 : 0.03),
                    in: .rect(cornerRadius: 8))
        .disabled(!enabled)
    }
}
