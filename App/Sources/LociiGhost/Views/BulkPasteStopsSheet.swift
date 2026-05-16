import SwiftUI

/// Bulk-paste sheet for multi-stop coordinates. The user pastes one
/// coordinate per line (`lat, lng` — comma / tab / semicolon all work)
/// and we append each one to `state.pendingStops` in the order pasted,
/// becoming Stop 1, Stop 2, … on the map.
///
/// Reuses `BookmarksJSONService.parseBulkPaste` for the actual line-by-
/// line lat/lng extraction: it already handles `lat,lng`, `name,lat,lng`,
/// blank lines, `#` comments, and out-of-range coordinate rejection.
/// We just discard the name/category fields that the bookmark variant
/// also captures — stops are coordinate-only.
struct BulkPasteStopsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText: String = ""
    @State private var previewCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.tint)
                Text("Bulk-add stops",
                     comment: "Title of the multi-stop bulk-paste sheet")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Text("Paste one coordinate per line — `lat, lng`. Comma, tab, or semicolon all work as separators. Lines starting with # are ignored. Stops are appended in the order pasted (Stop 1 = first line) to the end of your current list.",
                 comment: "Helper text in the multi-stop bulk-paste sheet")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 8-row paste area, mono-spaced so coordinates align.
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

            HStack {
                Image(systemName: previewCount > 0
                      ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(previewCount > 0 ? .green : .secondary)
                Text(previewCount == 0
                     ? String(localized: "Waiting for valid coordinates…",
                              comment: "Stops bulk-paste preview when no parseable lines yet")
                     : String(format: String(
                        localized: "%lld valid stops detected.",
                        comment: "Stops bulk-paste preview line count"),
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
                    let n = state.bulkAppendStops(from: pastedText)
                    if n > 0 { dismiss() }
                } label: {
                    Text("Add \(previewCount)",
                         comment: "Stops bulk-paste primary button — adds N stops")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(previewCount == 0)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
    }
}
