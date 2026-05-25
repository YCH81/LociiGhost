import SwiftUI

/// Modal sheet for creating or editing a bookmark. Two presentation
/// modes — driven by which AppState field is non-nil:
///
///   * `pendingBookmarkCoord != nil` → create-mode for that coordinate
///   * `editingBookmark != nil`      → edit-mode for that record
///
/// Both flows share the same form (name + category + icon picker);
/// Save funnels through `AppState.addBookmark` / `updateBookmark`
/// and the sheet dismisses by clearing whichever AppState field
/// triggered it.
struct BookmarkEditSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// Set in init from whichever AppState field was non-nil. A
    /// nil `editing` means we're in create-mode at `coord`.
    let coord: Coordinate
    let editing: Bookmark?

    @State private var name: String = ""
    @State private var category: String = ""
    @State private var iconSymbol: String = "mappin.circle.fill"

    /// Curated SF Symbol palette. Twelve icons cover the common
    /// "place type" cases (home, work, food, transit) without
    /// turning the picker into a 200-entry scroll.
    private static let iconChoices: [String] = [
        "mappin.circle.fill",
        "house.fill",
        "building.2.fill",
        "briefcase.fill",
        "fork.knife",
        "cup.and.saucer.fill",
        "cart.fill",
        "tram.fill",
        "airplane",
        "bed.double.fill",
        "heart.fill",
        "star.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: iconSymbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editing == nil
                         ? LocalizedStringKey("Save bookmark")
                         : LocalizedStringKey("Edit bookmark"))
                        .font(.headline)
                    Text(String(format: "%.5f, %.5f", coord.lat, coord.lng))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // v1.11.2: switched from Form+LabeledContent to Grid so
            // the Name and Category TextField column-edges actually
            // line up. LabeledContent inside a grouped Form lets
            // SwiftUI choose content widths per row, which left
            // Name (shorter placeholder) visibly narrower than
            // Category. Grid pins both TextFields to the same
            // trailing column, so they're guaranteed equal width.
            GroupBox {
                Grid(alignment: .leading,
                     horizontalSpacing: 12,
                     verticalSpacing: 12) {
                    GridRow {
                        Text("Name",
                             comment: "Bookmark form — name field label")
                            .font(.callout)
                            .gridColumnAlignment(.trailing)
                        TextField("e.g. 公司 / Home / 台北 101",
                                  text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("Category",
                             comment: "Bookmark form — optional grouping label")
                            .font(.callout)
                            .gridColumnAlignment(.trailing)
                        TextField("e.g. Work, Travel — leave blank for none",
                                  text: $category)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("Icon",
                             comment: "Bookmark form — SF Symbol picker label")
                            .font(.callout)
                            .gridColumnAlignment(.trailing)
                        iconPicker
                    }
                }
                .padding(8)
            }

            HStack {
                if editing != nil {
                    Button(role: .destructive) {
                        if let bm = editing { state.deleteBookmark(bm) }
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
        .onAppear {
            // Hydrate the form from `editing` if we're in edit mode.
            if let bm = editing {
                name = bm.name
                category = bm.category
                iconSymbol = bm.iconSymbol
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
        if let bm = editing {
            state.updateBookmark(bm, name: name, category: category, iconSymbol: iconSymbol)
        } else {
            state.addBookmark(name: name,
                              lat: coord.lat, lng: coord.lng,
                              category: category, iconSymbol: iconSymbol)
        }
        dismissAndClear()
    }

    private func dismissAndClear() {
        state.pendingBookmarkCoord = nil
        state.editingBookmark = nil
        dismiss()
    }
}
