import SwiftUI

/// Everything the compact card leaves out.
///
/// The card answers "which phone is this, and can I reach it". The
/// facts you only need occasionally — iOS version, developer mode,
/// which transports it supports, its udid — live here rather than
/// crowding four cards into a sidebar.
struct DeviceDetailsSheet: View {
    let device: DeviceVM
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var showingDevModeSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: state.deviceIcon(
                    for: device.udid,
                    fallback: device.isUSB ? "iphone.gen3"
                                           : "iphone.gen3.radiowaves.left.and.right"))
                    .font(.title)
                    .foregroundStyle(device.connected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.title3.weight(.semibold))
                    Text(device.connected
                         ? (device.isUSB
                            ? LocalizedStringKey("Connected over USB")
                            : LocalizedStringKey("Connected over WiFi"))
                         : LocalizedStringKey("Not connected"))
                        .font(.caption)
                        .foregroundStyle(device.connected ? Color.lociSage : .secondary)
                }
                Spacer()
            }

            Divider()

            row(LocalizedStringKey("iOS version"), value: device.iosVersion)
            row(LocalizedStringKey("Identifier"), value: device.udid)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Developer Mode")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Text(device.developerModeLabel)
                    .font(.callout)
                    .textSelection(.enabled)
                if device.developerModeNeedsAttention {
                    Button("Enable…") { showingDevModeSheet = true }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .sheet(isPresented: $showingDevModeSheet) {
            DeveloperModeSheet(device: device)
                .environment(state)
        }
    }

    private func row(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
