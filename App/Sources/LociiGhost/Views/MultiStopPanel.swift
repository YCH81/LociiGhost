import SwiftUI

/// Inline multi-stop panel. Multi-stop is just "click on the map a few
/// times and press Navigate"; the work happens in the existing on-map
/// ControlPanel. This panel exists to make that flow discoverable from
/// the sidebar and to centralise the trip-clear action.
struct MultiStopPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Click anywhere on the map to drop **Stop 1**, **Stop 2**, … in the order you want to visit them. Right-click also offers an Add-as-stop option.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.pendingStops.isEmpty {
                Text("No stops staged yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                stopsSummary
            }
        }
    }

    private var stopsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(state.pendingStops.count) stop\(state.pendingStops.count == 1 ? "" : "s") staged")
                .font(.caption.weight(.medium))
            ForEach(Array(state.pendingStops.enumerated()), id: \.offset) { idx, stop in
                HStack(spacing: 4) {
                    Text("\(idx + 1).")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tint)
                        .frame(width: 18, alignment: .trailing)
                    Text(String(format: "%.4f, %.4f", stop.lat, stop.lng))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Button(role: .destructive) {
                state.pendingStops = []
            } label: {
                Label("Clear all stops", systemImage: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }
}
