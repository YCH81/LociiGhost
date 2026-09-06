import SwiftUI

/// Reports the width its host is given, once per actual size change.
///
/// Exists because `ViewThatFits` cost too much where it was used. It
/// decides by building and measuring *every* candidate on every layout
/// pass, so putting it around a toolbar whose contents depend on the
/// selected device meant each device switch re-measured two full rows
/// of buttons: measured at ~115 ms of main-thread time per switch, out
/// of ~172 ms total. Reading one width and branching on it costs a
/// single layout pass and nothing on the passes in between.
struct BarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Calls `onChange` when the available width changes.
    func readingBarWidth(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: BarWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(BarWidthKey.self) { onChange($0) }
    }
}
