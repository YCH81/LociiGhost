import SwiftUI

/// v1.11.2: edit the waypoints of a saved Route — reorder by drag,
/// type into lat/lng fields, add or delete points. Three exits:
///
///   * **Cancel** — drop changes, close
///   * **Run once (no save)** — execute the edited list as a one-shot
///     trip without touching the underlying Route record
///   * **Save changes** — write the edited points back to the Route
///
/// Mirrors MultiStopPanel's drag-handle reorder pattern so the UX
/// feels familiar to anyone who's already staged stops by clicking
/// on the map. The on-disk Route is only touched on Save Changes;
/// Cancel and Run-once leave it alone.
struct RouteWaypointsEditSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let route: Route

    /// Wraps each row with a stable UUID so SwiftUI's drag/drop
    /// machinery can match the dragged item to its row across
    /// re-renders. Coordinate alone isn't `Identifiable` and two
    /// stops at the same coords would collide on `\.self`.
    struct EditableWaypoint: Identifiable, Hashable {
        let id: UUID = UUID()
        var lat: Double
        var lng: Double
    }

    @State private var waypoints: [EditableWaypoint] = []
    @State private var draggingId: UUID?
    /// Deferred-load flag: sheet presents first (empty), then the Task
    /// below fills `waypoints`. This unblocks the presentation animation
    /// so a 234-point route doesn't freeze the UI for 2+ seconds while
    /// SwiftUI tries to eagerly render every row at once.
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            // Waypoint list — LazyVStack so only visible rows are built.
            // An eager VStack with 234 rows × 2 format-based TextFields
            // + draggable/dropDestination modifiers caused a 2-second
            // freeze on sheet open (all rows rendered synchronously in
            // the first layout pass). LazyVStack defers off-screen rows.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(waypoints.indices, id: \.self) { idx in
                        waypointRow(idx: idx)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)
            .overlay {
                if !loaded {
                    // Brief skeleton while the .task hydrates
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if waypoints.isEmpty {
                    Text("No waypoints yet. Tap **Add waypoint** to begin.",
                         comment: "Empty-state hint inside RouteWaypointsEditSheet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(20)
                }
            }

            HStack(spacing: 10) {
                Button {
                    addWaypoint()
                } label: {
                    Label {
                        Text("Add waypoint",
                             comment: "RouteWaypointsEditSheet — append a new waypoint to the end of the list")
                    } icon: {
                        Image(systemName: "plus.circle")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Text(String(
                    format: String(
                        localized: "%lld points",
                        comment: "RouteWaypointsEditSheet — count of waypoints in the editor",
                    ),
                    waypoints.count,
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            actionRow
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 500)
        // .task runs after the sheet's first layout pass completes,
        // so the window appears immediately and the spinner shows
        // for the brief moment while JSON is decoded + UUID objects
        // are allocated. Avoids blocking the presentation animation.
        .task {
            hydrate()
            loaded = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: route.iconSymbol)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit waypoints",
                     comment: "RouteWaypointsEditSheet — title")
                    .font(.headline)
                Text(route.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func waypointRow(idx: Int) -> some View {
        let wp = waypoints[idx]
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(LocalizedStringKey("Drag to reorder"))
            Text("\(idx + 1).")
                .font(.caption.monospaced())
                .foregroundStyle(.tint)
                .frame(width: 32, alignment: .trailing)
            TextField(
                String(localized: "lat",
                       comment: "RouteWaypointsEditSheet — placeholder for the latitude TextField"),
                value: latBinding(idx),
                format: .number.precision(.fractionLength(0...6)),
            )
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            TextField(
                String(localized: "lng",
                       comment: "RouteWaypointsEditSheet — placeholder for the longitude TextField"),
                value: lngBinding(idx),
                format: .number.precision(.fractionLength(0...6)),
            )
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Spacer(minLength: 4)
            Button {
                waypoints.remove(at: idx)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.75))
            }
            .buttonStyle(.borderless)
            .help(LocalizedStringKey("Delete this waypoint"))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            draggingId == wp.id
                ? AnyShapeStyle(Color.lociSage.opacity(0.18))
                : AnyShapeStyle(Color.clear),
            in: .rect(cornerRadius: 4),
        )
        .contentShape(.rect)
        .hoverHighlight(cornerRadius: 4, changesCursor: false)
        .draggable(WaypointDragPayload(id: wp.id)) {
            Text("\(idx + 1). \(String(format: "%.4f, %.4f", wp.lat, wp.lng))")
                .font(.caption2.monospaced())
                .padding(6)
                .background(.regularMaterial, in: .rect(cornerRadius: 4))
        }
        .dropDestination(for: WaypointDragPayload.self) { items, _ in
            guard let payload = items.first else { return false }
            move(sourceId: payload.id, toIndex: idx)
            draggingId = nil
            return true
        } isTargeted: { isTargeted in
            if isTargeted { draggingId = wp.id }
        }
    }

    // MARK: - Bindings

    /// Per-row lat binding. Built via index lookup (not array
    /// element binding) because Coordinate isn't `Identifiable`
    /// and we want plain value-type editing semantics — change
    /// fires only when the TextField commits a parsed Double.
    private func latBinding(_ idx: Int) -> Binding<Double> {
        Binding(
            get: { waypoints[idx].lat },
            set: { waypoints[idx].lat = $0 },
        )
    }

    private func lngBinding(_ idx: Int) -> Binding<Double> {
        Binding(
            get: { waypoints[idx].lng },
            set: { waypoints[idx].lng = $0 },
        )
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Cancel") { dismissAndClear() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                runOnceUnsaved()
            } label: {
                Label {
                    Text("Run once (no save)",
                         comment: "RouteWaypointsEditSheet — execute the edited waypoints as a one-shot trip without writing back")
                } icon: {
                    Image(systemName: "play.fill")
                }
            }
            .disabled(waypoints.isEmpty || state.selectedUDID == nil)
            .help(LocalizedStringKey("Run this trip once without overwriting the saved route"))

            Button {
                saveChanges()
            } label: {
                Label {
                    Text("Save changes",
                         comment: "RouteWaypointsEditSheet — write the edited waypoints back to the saved Route")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(waypoints.isEmpty)
        }
    }

    // MARK: - State management

    @MainActor
    private func hydrate() {
        waypoints = route.points.map { EditableWaypoint(lat: $0.lat, lng: $0.lng) }
    }

    private func addWaypoint() {
        // Default new point to the last entry's coords so the user has
        // a sane jumping-off point instead of (0,0) in the middle of
        // the Atlantic. Empty list → (0, 0) and the user types over.
        let last = waypoints.last
        waypoints.append(EditableWaypoint(
            lat: last?.lat ?? 0,
            lng: last?.lng ?? 0,
        ))
    }

    private func move(sourceId: UUID, toIndex: Int) {
        guard let from = waypoints.firstIndex(where: { $0.id == sourceId }) else {
            return
        }
        let removed = waypoints.remove(at: from)
        let dest = (toIndex > from) ? max(0, toIndex - 1) : min(waypoints.count, toIndex)
        waypoints.insert(removed, at: dest)
    }

    private func saveChanges() {
        let coords = waypoints.map { Coordinate(lat: $0.lat, lng: $0.lng) }
        state.updateRouteWaypoints(route, points: coords)
        dismissAndClear()
    }

    private func runOnceUnsaved() {
        let coords = waypoints.map { Coordinate(lat: $0.lat, lng: $0.lng) }
        guard let udid = state.selectedUDID else { return }
        Task { await state.runAdHocRoute(coords: coords, udid: udid) }
        dismissAndClear()
    }

    private func dismissAndClear() {
        state.editingRouteWaypoints = nil
        dismiss()
    }
}

/// Drag payload — same shape as MultiStopPanel's StopDragPayload so
/// the two reorder flows feel identical and there's no chance of
/// cross-list drag interference (separate Transferable types).
private struct WaypointDragPayload: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
