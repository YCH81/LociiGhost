import SwiftUI

/// Modal sheet for naming a freshly-imported GPX (create-mode) or
/// renaming / re-categorising an existing saved Route (edit-mode).
/// Mirrors BookmarkEditSheet's two-mode pattern: which AppState field
/// is non-nil determines the mode.
///
///   * `pendingRouteImport != nil` → create-mode for those coords
///   * `editingRoute != nil`       → edit-mode for that record
///
/// Saving funnels through `AppState.saveImportedRoute` /
/// `AppState.updateRoute`; cancel just clears the AppState fields and
/// dismisses (the imported coordinates are dropped on cancel — the
/// user can re-import the GPX if they change their mind).
struct RouteEditSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// In CREATE mode: the parsed GPX coordinates and a filename
    /// stem for the name field. nil in EDIT mode (we read the
    /// coordinates off `editing.points` instead).
    let pending: PendingRouteImport?
    /// In EDIT mode: the Route to update. nil in CREATE mode.
    let editing: Route?

    @State private var name: String = ""
    @State private var category: String = ""
    @State private var iconSymbol: String = "point.bottomleft.forward.to.point.topright.scurvepath.fill"

    /// Curated palette of "path-shape" SF Symbols. Kept smaller than
    /// the bookmark palette because routes are intrinsically more
    /// uniform — twelve point/place glyphs don't fit recorded paths.
    private static let iconChoices: [String] = [
        "point.bottomleft.forward.to.point.topright.scurvepath.fill",
        "map.fill",
        "figure.walk",
        "bicycle",
        "car.fill",
        "tram.fill",
        "mountain.2.fill",
        "leaf.fill",
        "globe.asia.australia.fill",
        "flag.checkered",
        "arrow.triangle.turn.up.right.diamond.fill",
        "scribble.variable",
    ]

    private var pointCount: Int {
        if let editing { return editing.pointCount }
        return pending?.coordinates.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: iconSymbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editing == nil
                         ? LocalizedStringKey("Save route")
                         : LocalizedStringKey("Edit route"))
                        .font(.headline)
                    Text(String(
                        format: String(
                            localized: "%lld points",
                            comment: "RouteEditSheet subtitle — total imported coords",
                        ),
                        pointCount,
                    ))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Form {
                LabeledContent {
                    TextField("e.g. 東京晨跑 / Sunday hike",
                              text: $name)
                        .textFieldStyle(.roundedBorder)
                } label: {
                    Text("Name",
                         comment: "Route form — name field label")
                }

                LabeledContent {
                    TextField("e.g. Travel, Training — leave blank for none",
                              text: $category)
                        .textFieldStyle(.roundedBorder)
                } label: {
                    Text("Category",
                         comment: "Route form — optional grouping label")
                }

                LabeledContent {
                    iconPicker
                } label: {
                    Text("Icon",
                         comment: "Route form — SF Symbol picker label")
                }
            }
            .formStyle(.grouped)

            HStack {
                if editing != nil {
                    Button(role: .destructive) {
                        if let r = editing { state.deleteRoute(r) }
                        dismissAndClear()
                    } label: {
                        Label("Delete",
                              systemImage: "trash")
                    }
                }
                Spacer()
                Button("Cancel") { dismissAndClear() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
        .onAppear {
            // Hydrate the form from whichever mode triggered us.
            if let r = editing {
                name = r.name
                category = r.category
                iconSymbol = r.iconSymbol
            } else if let p = pending {
                name = p.suggestedName
            }
        }
    }

    private var iconPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6),
                  spacing: 6) {
            ForEach(Self.iconChoices, id: \.self) { sym in
                Button {
                    iconSymbol = sym
                } label: {
                    Image(systemName: sym)
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .background(
                            iconSymbol == sym
                                ? AnyShapeStyle(Color.lociSage.opacity(0.25))
                                : AnyShapeStyle(Color.secondary.opacity(0.10)),
                            in: .rect(cornerRadius: 6),
                        )
                        .foregroundStyle(iconSymbol == sym
                                         ? Color.lociSage : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func save() {
        if let r = editing {
            state.updateRoute(r, name: name, category: category, iconSymbol: iconSymbol)
        } else if let p = pending {
            state.saveImportedRoute(name: name,
                                    coordinates: p.coordinates,
                                    category: category,
                                    iconSymbol: iconSymbol)
        }
        dismissAndClear()
    }

    private func dismissAndClear() {
        state.pendingRouteImport = nil
        state.editingRoute = nil
        dismiss()
    }
}
