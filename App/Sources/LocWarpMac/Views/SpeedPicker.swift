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
                    Label(p.label, systemImage: p.symbol).tag(p)
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
                Text(String(format: "Effective: %.1f km/h", effectiveKmh))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if state.customSpeedMps != nil {
                    Text("(custom)")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 3))
                        .foregroundStyle(Color.accentColor)
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
