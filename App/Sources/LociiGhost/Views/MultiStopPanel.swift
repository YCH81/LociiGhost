import SwiftUI
import SwiftData

/// Inline multi-stop panel. Multi-stop is "click on the map a few
/// times and press Navigate"; the work happens in the on-map
/// ControlPanel.
///
/// Sidebar surface owned by this view:
///   * a brief instruction line
///   * the staged-stops list — each row carries a drag-handle so
///     the user can re-order stops to change visit order without
///     deleting and re-adding
///   * `Clear all stops` (destructive), `Save as new route`, and
///     `Save as preset` (v1.11.0 — multi-stop "favourites" the user
///     can recall later via the Presets list below)
///   * Presets list (v1.11.0): saved `StopPreset` entries, click to
///     load via `LoadStopPresetSheet`'s Cancel / Display / Teleport
///     confirmation
struct MultiStopPanel: View {
    @Environment(AppState.self) private var state
    @Query(sort: [SortDescriptor(\StopPreset.createdAt, order: .reverse)])
    private var presets: [StopPreset]
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
        @Bindable var state = state
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

            DwellModeRow()
                .help(LocalizedStringKey("With dwell on, the iPhone pauses the chosen number of seconds at each stop before continuing to the next"))

            if state.pendingStops.isEmpty {
                Text("No stops staged yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // v1.11.0: sidebar mirror of the on-map "Show controls"
                // chip. When the user X-dismissed the ControlPanel popup,
                // they may not look back to the map to find the chip —
                // surface the re-open entry here too so it's reachable
                // wherever the user happens to be focused.
                if state.navigationControlsHidden {
                    Button {
                        state.navigationControlsHidden = false
                    } label: {
                        Label("Show route controls",
                              systemImage: "list.bullet.below.rectangle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .hoverHighlight(cornerRadius: 5)
                    .help(LocalizedStringKey("Reopen the route controls"))
                }
                stopsSummary
            }

            // v1.11.0: Presets list. Always visible (even with no
            // staged stops yet) so the user can click a saved preset
            // → LoadStopPresetSheet → load into staging.
            if !presets.isEmpty {
                presetsSection
            }
        }
        .sheet(isPresented: $showingBulkPaste) {
            BulkPasteStopsSheet()
        }
    }

    /// Saved-presets list. Right-click on a row → Delete; left-click
    /// parks the preset in `state.presetPendingLoad` which surfaces
    /// the confirmation sheet (Cancel / Display / Teleport).
    @ViewBuilder
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                    .font(.caption2)
                Text("Saved stop presets",
                     comment: "Section header above the saved StopPreset list")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(presets.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 6)

            ForEach(presets) { preset in
                Button {
                    state.presetPendingLoad = preset
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bookmark")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(preset.stopCount) stops")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 4, changesCursor: false)
                .contextMenu {
                    Button(role: .destructive) {
                        state.deleteStopPreset(preset)
                    } label: {
                        Label("Delete preset", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var stopsSummary: some View {
        let stops = stagedStops
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(state.pendingStops.count) stop\(state.pendingStops.count == 1 ? "" : "s") staged")
                .font(.caption.weight(.medium))

            // Cap the visible list at ~280pt — long pastes (50+ stops)
            // would otherwise render every row as a sibling of the
            // VStack and grow the whole panel past the screen with no
            // way to scroll. ScrollView keeps the row drag-handles +
            // delete buttons all reachable; the count label and action
            // row stay anchored below.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stops.enumerated()), id: \.element.id) { (idx, stop) in
                        stopRow(idx: idx, stop: stop, totalStops: stops)
                    }
                }
            }
            .frame(maxHeight: 280)

            // Three actions wrap to a second row if the panel is
            // narrower than ~280 pt — Clear (destructive) stays first,
            // Save-as-preset is the lightweight "remember these stops"
            // action, Save-as-route is the heavier "promote to sidebar
            // Routes section" action.
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
                    state.presetPendingSave = true
                } label: {
                    Label("Save as preset",
                          systemImage: "bookmark.fill")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .hoverHighlight(cornerRadius: 5)
                .help(LocalizedStringKey("Save these stops as a named preset — click it later to reload the same staging"))

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

/// Shared row of "Dwell at each stop" toggle + N-seconds stepper.
/// Lives both in the sidebar's MultiStopPanel and (since v1.11.0)
/// in the on-map ControlPanel popup, so the user can flip dwell on
/// without leaving whichever surface they're operating.
///
/// The stepper is conditionally rendered (instead of permanently
/// shown with `.disabled`) because macOS's `.disabled` Stepper
/// renders the +/- buttons at a low-contrast grey that some users
/// were misreading as "uninteractive" even when dwell was on.
struct DwellModeRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 8) {
            Toggle(isOn: $state.dwellEnabled) {
                Text("Dwell at each stop",
                     comment: "Toggle that makes Navigate pause N seconds at every stop")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            Spacer(minLength: 6)
            if state.dwellEnabled {
                Stepper(
                    value: $state.dwellSeconds,
                    in: 1...3600,
                    step: 5,
                ) {
                    Text("\(state.dwellSeconds) s",
                         comment: "Dwell duration stepper label, in seconds")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
        }
    }
}
