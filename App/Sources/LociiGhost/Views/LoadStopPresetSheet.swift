import SwiftUI

/// Sheet shown when the user clicks a saved `StopPreset` row in the
/// Multi-Stop panel. Two-action confirmation:
///
///   * **Display only** — load the preset's coordinates into
///     `pendingStops` and re-centre the map on the first one. The
///     iPhone stays where it currently is; user can inspect / edit
///     the staged stops, then press Navigate manually.
///   * **Teleport to first stop** — same as above PLUS instantly move
///     the iPhone to the preset's first coordinate, so the user can
///     press Navigate and start moving without a long initial leg
///     from wherever the iPhone happened to be.
///
/// Cancel just dismisses; no state mutation. Matches the spec from
/// v1.11.0 where the user explicitly wanted "if I just want to see
/// the points, don't move the iPhone" as a distinct flow from "I'm
/// going to start the route, teleport me there".
struct LoadStopPresetSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let preset: StopPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark")
                    .foregroundStyle(.tint)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .font(.title3.weight(.semibold))
                    Text(String(
                        format: String(
                            localized: "%lld stops",
                            comment: "Load-preset subtitle showing stop count",
                        ),
                        preset.stopCount,
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Load these stops into the Multi-Stop panel. Choose whether to also teleport the iPhone to the first stop — Display Only just stages and re-centres the map, while Teleport to First moves the iPhone there immediately so Navigate starts cleanly.",
                 comment: "Load-preset sheet body — explains the two confirmation options")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") {
                    state.presetPendingLoad = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    fire(teleport: false)
                } label: {
                    Label {
                        Text("Display only",
                             comment: "Load-preset secondary action — stage + map-recentre, no teleport")
                    } icon: {
                        Image(systemName: "eye")
                    }
                }

                Button {
                    fire(teleport: true)
                } label: {
                    Label {
                        Text("Teleport to first",
                             comment: "Load-preset primary action — stage + teleport iPhone to stop 1")
                    } icon: {
                        Image(systemName: "wand.and.stars")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func fire(teleport: Bool) {
        let p = preset
        state.presetPendingLoad = nil
        dismiss()
        Task { @MainActor in
            await state.loadStopPreset(p, teleport: teleport)
        }
    }
}
