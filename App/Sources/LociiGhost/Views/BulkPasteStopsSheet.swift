import AppKit
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

            Text("Paste one coordinate per line — `lat, lng`. Comma, tab, or semicolon all work as separators; lines starting with # are ignored. The iPhone teleports to the first pasted coordinate so path-planning starts locally; any previously staged stops are cleared.",
                 comment: "Helper text in the multi-stop bulk-paste sheet")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Fixed-height paste area (~15 visible rows), mono-spaced so
            // coordinates align. SwiftUI's TextEditor on macOS exceeds
            // its `.frame(height:)` when pasted content overflows — the
            // underlying NSTextView's intrinsic height takes over, the
            // VStack stretches, and the sheet window grows past its
            // outer .frame. BoundedTextEditor wraps NSTextView in an
            // NSScrollView of the requested height so overflow scrolls
            // internally instead of pushing layout.
            BoundedTextEditor(text: $pastedText)
                .frame(height: 280)
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
                    Task { @MainActor in
                        let n = await state.bulkAppendStops(from: pastedText)
                        if n > 0 { dismiss() }
                    }
                } label: {
                    Text("Add \(previewCount)",
                         comment: "Stops bulk-paste primary button — adds N stops")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(previewCount == 0)
            }
        }
        .padding(24)
        // Pin the sheet at a fixed footprint. With BoundedTextEditor
        // above keeping its NSTextView inside an NSScrollView of the
        // requested 280pt, the VStack no longer grows vertically when
        // the user pastes a long block of stops.
        .frame(width: 540, height: 500)
    }
}

/// macOS-only multi-line text editor that strictly honours its frame.
///
/// SwiftUI's `TextEditor` lets its underlying NSTextView grow to its
/// intrinsic content size, ignoring `.frame(height:)` and pushing the
/// parent layout. Wrapping NSTextView in an NSScrollView pinned at the
/// requested height makes content overflow scroll internally instead.
fileprivate struct BoundedTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        if let tv = scrollView.documentView as? NSTextView {
            tv.delegate = context.coordinator
            tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            tv.isRichText = false
            tv.allowsUndo = true
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.drawsBackground = false
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let textBinding: Binding<String>
        init(text: Binding<String>) { self.textBinding = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            textBinding.wrappedValue = tv.string
        }
    }
}
