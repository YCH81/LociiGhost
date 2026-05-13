import SwiftUI

/// Bulk-paste sheet — accepts multiple lines of `name,lat,lng[,category]`
/// or `lat,lng[,name][,category]` and creates one bookmark per line.
/// Tab, comma, or semicolon all work as separators. Lines starting
/// with `#` are treated as comments and skipped.
///
/// Opens from the BookmarksSection menu; closes automatically once
/// the user clicks Add (or Cancel). The toast at the bottom of the
/// map shows how many entries were actually inserted vs. skipped.
struct BulkPasteBookmarksSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText: String = ""
    @State private var defaultCategory: String = ""
    @State private var previewCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.tint)
                Text("Bulk-add bookmarks",
                     comment: "Title of the bulk-paste bookmark sheet")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Text("Paste one bookmark per line. Each line can be `name, lat, lng` or `lat, lng, name`. Comma, tab, or semicolon all work. Lines starting with # are ignored.",
                 comment: "Helper text in the bulk-paste bookmark sheet")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Default category for lines that don't include one.
            // Trimmed empty stays as "Uncategorized" — same convention
            // as the rest of the bookmark sidebar.
            HStack {
                Text("Default category:",
                     comment: "Field label in the bulk-paste sheet")
                TextField(
                    String(localized: "Optional",
                           comment: "Placeholder in the bulk-paste sheet's default-category field"),
                    text: $defaultCategory
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                Spacer()
            }

            // The actual paste area. Mono so coordinates stay aligned.
            // 8 rows is the sweet spot — fits a typical paste from a
            // spreadsheet (10-ish places) with light scrolling, but
            // doesn't dominate the sheet visually.
            TextEditor(text: $pastedText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
                .onChange(of: pastedText) { _, newValue in
                    previewCount = BookmarksJSONService.parseBulkPaste(newValue).count
                }

            // Live preview count — gives the user immediate feedback
            // that their separators / line shape is being recognised
            // before they click Add.
            HStack {
                Image(systemName: previewCount > 0
                      ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(previewCount > 0 ? .green : .secondary)
                Text(previewCount == 0
                     ? String(localized: "Waiting for valid lines…",
                              comment: "Bulk-paste sheet preview when no parseable lines yet")
                     : String(format: String(
                        localized: "%lld valid bookmarks detected.",
                        comment: "Bulk-paste sheet preview line count"),
                              previewCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let n = state.bulkAddBookmarks(
                        from: pastedText,
                        defaultCategory: defaultCategory,
                    )
                    if n > 0 { dismiss() }
                } label: {
                    Text("Add \(previewCount)",
                         comment: "Bulk-paste sheet primary button — adds N bookmarks")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(previewCount == 0)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
    }
}
