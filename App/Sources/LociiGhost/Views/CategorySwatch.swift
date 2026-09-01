import SwiftUI
import LociiGhostCore

/// Turns a `CategoryPalette` hex into a SwiftUI `Color`.
///
/// The conversion lives here, in one place, rather than at each call
/// site: the sidebar dot, the map pin tint and the picker all have to
/// agree, and "the same colour computed three ways" is how they stop
/// agreeing. Core hands out components rather than a `Color` so the
/// AppKit map path can build an `NSColor` from the same numbers.
enum CategorySwatch {
    static func color(_ hex: String) -> Color {
        guard let c = CategoryPalette.components(hex) else { return .secondary }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    static func nsColor(_ hex: String) -> NSColor {
        guard let c = CategoryPalette.components(hex) else { return .secondaryLabelColor }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

/// The colour picker offered on a category: the ten palette entries
/// plus a way back to the derived default.
///
/// Ten fixed swatches rather than a free colour well, because the
/// palette entries are the ones chosen to stay legible on both a light
/// and a dark ground — a colour well would happily hand back white,
/// and the user would only discover the problem after switching theme.
struct CategoryColorMenu: View {
    @Environment(AppState.self) private var state
    let category: String

    var body: some View {
        Menu {
            ForEach(CategoryPalette.hexes, id: \.self) { hex in
                Button {
                    state.setCategoryColor(hex, for: category)
                } label: {
                    Label {
                        Text(verbatim: hex)
                    } icon: {
                        Image(systemName: isCurrent(hex) ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(CategorySwatch.color(hex))
                    }
                }
            }
            Divider()
            Button {
                state.setCategoryColor(nil, for: category)
            } label: {
                Text("Use the automatic colour",
                     comment: "Category colour menu — revert to the name-derived default")
            }
            .disabled(state.categoryColorOverrides[CategoryPalette.key(for: category)] == nil)
        } label: {
            Label {
                Text("Category colour",
                     comment: "Context-menu title for choosing a bookmark category's colour")
            } icon: {
                Image(systemName: "paintpalette")
            }
        }
    }

    private func isCurrent(_ hex: String) -> Bool {
        state.categoryColorHex(category).caseInsensitiveCompare(hex) == .orderedSame
    }
}
