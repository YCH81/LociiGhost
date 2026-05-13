import SwiftUI

/// Shared speed-selection control reused by ControlPanel and the
/// inline movement-mode panels. Combines the three travel-profile
/// presets with a free-form "Custom" entry: typing a number into the
/// custom field and pressing **Use** sets `state.customSpeedMps`,
/// which then overrides the profile's default everywhere a route or
/// mode reads the effective speed.
struct SpeedPicker: View {
    @Environment(AppState.self) private var state
    @State private var customInput: String = ""

    /// Current effective speed (custom override → profile default).
    private var effectiveKmh: Double {
        (state.customSpeedMps ?? state.travelProfile.defaultSpeedMps) * 3.6
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $state.travelProfile) {
                ForEach(TravelProfile.allCases) { p in
                    Label(p.labelKey, systemImage: p.symbol).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: state.travelProfile) { _, _ in
                // Picking a preset means "use this preset's speed",
                // which logically clears any prior custom override.
                state.customSpeedMps = nil
                customInput = ""
            }

            HStack(spacing: 6) {
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("km/h", text: $customInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit { applyCustom() }
                Button("Use") { applyCustom() }
                    .controlSize(.small)
                    .disabled(parsedCustomKmh == nil)
                if state.customSpeedMps != nil {
                    Button {
                        state.customSpeedMps = nil
                        customInput = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Drop the custom speed and use the picker's preset")
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .foregroundStyle(.secondary)
                // Pre-format the number into a String so the SwiftUI
                // `LocalizedStringKey` ends up with `%@` (catalog-
                // friendly) instead of `%lf` (which can fail lookup
                // on some Apple toolchains). Resulting key:
                // "Speed: %@ km/h" — matches both .lproj catalogs.
                Text("Speed: \(String(format: "%.1f", effectiveKmh)) km/h",
                     comment: "Effective speed readout under the SpeedPicker; first %@ is the km/h value")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if state.customSpeedMps != nil {
                    Text("(custom)",
                         comment: "Badge next to the speed readout when the user typed a custom value")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.lociSage.opacity(0.18), in: .rect(cornerRadius: 3))
                        .foregroundStyle(Color.lociSage)
                }
            }
        }
    }

    private var parsedCustomKmh: Double? {
        let trimmed = customInput.trimmingCharacters(in: .whitespaces)
        guard let v = Double(trimmed), v > 0, v < 1_000 else { return nil }
        return v
    }

    private func applyCustom() {
        guard let kmh = parsedCustomKmh else { return }
        state.customSpeedMps = kmh / 3.6
    }
}
