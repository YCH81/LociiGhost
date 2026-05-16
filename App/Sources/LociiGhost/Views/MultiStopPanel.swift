import SwiftUI

/// Inline multi-stop panel. Multi-stop is "click on the map a few
/// times and press Navigate"; the work happens in the on-map
/// ControlPanel.
///
/// Sidebar surface owned by this view:
///   * a brief instruction line
///   * the staged-stops list — each row carries a drag-handle so
///     the user can re-order stops to change visit order without
///     deleting and re-adding
///   * `Clear all stops` (destructive) and `Save as new route`
///     (saves the current staging as a SwiftData Route record so
///     the user can replay this trip later without re-clicking)
struct MultiStopPanel: View {
    @Environment(AppState.self) private var state
    @State private var draggingStopID: StagedStop.ID?
    @State private var showingBulkPaste: Bool = false

    /// Wrap each stop in a struct with a stable id so SwiftUI's
    /// drag-and-drop machinery can match the dragged item to the
    /// list row across re-renders. The raw `[Coordinate]` would
    /// give us only `\.offset` (positional) ids, which break the
    /// instant a reorder happens.
    private struct StagedStop: Identifiable, Hashable {
        let id: UUID
        let coord: Coordinate
    }

    private var stagedStops: [StagedStop] {
        state.pendingStops.map { StagedStop(id: stableID(for: $0), coord: $0) }
    }

    /// Stable per-coordinate UUID, derived from a hash of the
    /// lat/lng. Two stops at IDENTICAL coordinates would collide
    /// and break dragging — but that's a degenerate case (clicked
    /// the exact same map pixel twice) and not worth a separate
    /// id table to defend against.
    private func stableID(for c: Coordinate) -> UUID {
        var hasher = Hasher()
        hasher.combine(c.lat)
        hasher.combine(c.lng)
        let h = hasher.finalize()
        let bytes = withUnsafeBytes(of: h.littleEndian) { Array($0) }
        var uuid = uuid_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        for i in 0..<min(8, bytes.count) {
            withUnsafeMutableBytes(of: &uuid) { $0[i] = bytes[i] }
        }
        return UUID(uuid: uuid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Click anywhere on the map to drop **Stop 1**, **Stop 2**, … in the order you want to visit them. Right-click also offers an Add-as-stop option.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Drag a row's handle to reorder stops.",
                 comment: "MultiStopPanel — hint that stops can be re-ordered via drag")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Always-visible Bulk-add affordance. Click-by-click stop
            // entry is fine for 3–5 stops but breaks down for a long
            // pre-planned route; this button opens a paste sheet that
            // accepts one `lat, lng` per line and appends each to the
            // end of pendingStops in order.
            Button {
                showingBulkPaste = true
            } label: {
                Label("Bulk-add coordinates…",
                      systemImage: "doc.on.clipboard")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .hoverHighlight(cornerRadius: 5)
            .help(LocalizedStringKey("Paste many coordinates at once — each line becomes the next stop"))

            if state.pendingStops.isEmpty {
                Text("No stops staged yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                stopsSummary
            }
        }
        .sheet(isPresented: $showingBulkPaste) {
            BulkPasteStopsSheet()
        }
    }

    private var stopsSummary: some View {
        let stops = stagedStops
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(state.pendingStops.count) stop\(state.pendingStops.count == 1 ? "" : "s") staged")
                .font(.caption.weight(.medium))

            ForEach(Array(stops.enumerated()), id: \.element.id) { (idx, stop) in
                stopRow(idx: idx, stop: stop, totalStops: stops)
            }

            HStack(spacing: 6) {
                Button(role: .destructive) {
                    state.pendingStops = []
                } label: {
                    Label("Clear all stops", systemImage: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .hoverHighlight(cornerRadius: 5)

                Button {
                    state.stagePendingStopsAsRoute()
                } label: {
                    Label("Save as new route",
                          systemImage: "point.bottomleft.forward.to.point.topright.scurvepath.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .hoverHighlight(cornerRadius: 5)
                .help(LocalizedStringKey("Save these stops as a Route so you can replay this trip later"))
            }
            .padding(.top, 2)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }

    @ViewBuilder
    private func stopRow(idx: Int,
                         stop: StagedStop,
                         totalStops: [StagedStop]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(LocalizedStringKey("Drag to reorder"))
            Text("\(idx + 1).")
                .font(.caption2.monospaced())
                .foregroundStyle(.tint)
                .frame(width: 18, alignment: .trailing)
            Text(String(format: "%.4f, %.4f", stop.coord.lat, stop.coord.lng))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            draggingStopID == stop.id
                ? AnyShapeStyle(Color.lociSage.opacity(0.18))
                : AnyShapeStyle(Color.clear),
            in: .rect(cornerRadius: 4),
        )
        .contentShape(.rect)
        .hoverHighlight(cornerRadius: 4, changesCursor: false)
        // SwiftUI native drag-and-drop. The drop closure mutates
        // pendingStops directly; the schedulePreviewRefresh path
        // (driven by .onChange in MainView) re-renders the route
        // preview line on the map automatically.
        .draggable(StopDragPayload(id: stop.id)) {
            Text("\(idx + 1). \(String(format: "%.4f, %.4f", stop.coord.lat, stop.coord.lng))")
                .font(.caption2.monospaced())
                .padding(6)
                .background(.regularMaterial, in: .rect(cornerRadius: 4))
        }
        .dropDestination(for: StopDragPayload.self) { items, _ in
            guard let payload = items.first else { return false }
            move(sourceID: payload.id, toIndex: idx)
            draggingStopID = nil
            return true
        } isTargeted: { isTargeted in
            if isTargeted { draggingStopID = stop.id }
        }
    }

    /// Reorder pendingStops so the stop with `sourceID` lands at
    /// `toIndex`. No-op if either side can't be resolved or the
    /// move would be a no-op (same position).
    private func move(sourceID: UUID, toIndex: Int) {
        let stops = stagedStops
        guard let from = stops.firstIndex(where: { $0.id == sourceID }) else {
            return
        }
        var coords = state.pendingStops
        let removed = coords.remove(at: from)
        // Adjust target index: if we're moving forward, every
        // element after `from` shifts left by one, so the target
        // slot is one less than the click-target's index.
        let dest = (toIndex > from) ? max(0, toIndex - 1) : min(coords.count, toIndex)
        coords.insert(removed, at: dest)
        if coords != state.pendingStops {
            state.pendingStops = coords
        }
    }
}

/// Type-safe drag payload so SwiftUI's drag-and-drop machinery
/// only matches our stop rows (not arbitrary text drops). The id
/// alone is enough — the receiving row knows its own coordinate.
private struct StopDragPayload: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
