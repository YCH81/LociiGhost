import SwiftUI

/// Sheet shown when the user clicks "Save as preset" in the Multi-Stop
/// panel. Just asks for a name (the coords come from the current
/// `state.pendingStops`). Save creates a `StopPreset` and dismisses;
/// the new preset shows up in the panel's presets list.
struct SavePresetSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    /// Cached at the moment the sheet opens so the title can show
    /// "Save 12 stops as preset" without reading state.pendingStops
    /// on every redraw.
    private var stopCount: Int { state.pendingStops.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Save as preset",
                         comment: "Title of the save-stops-as-preset sheet")
                        .font(.title3.weight(.semibold))
                    Text(String(
                        format: String(
                            localized: "%lld stops will be stored under this name",
                            comment: "Save-preset subtitle showing how many stops are being saved",
                        ),
                        stopCount,
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name",
                     comment: "Save-preset name field label")
                    .font(.callout)
                TextField(
                    String(localized: "e.g. Downtown Tokyo evening loop",
                           comment: "Save-preset name placeholder"),
                    text: $name
                )
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { savePreset() }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    state.presetPendingSave = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    savePreset()
                } label: {
                    Text("Save",
                         comment: "Confirm button on the save-preset sheet")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }

    private func savePreset() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.saveCurrentStopsAsPreset(name: trimmed)
        state.presetPendingSave = false
        dismiss()
    }
}
