import SwiftUI
import AppKit

/// View modifier that paints a subtle background tint and flips the
/// cursor to a pointing hand whenever the mouse enters the view.
///
/// Used for the many buttons in our UI that use `.borderless` or
/// `.plain` button styles — those styles strip macOS's built-in hover
/// feedback, so without this the user can't tell whether the cursor
/// is over a clickable surface or just hanging in space.
///
/// We don't use this on `.buttonStyle(.bordered)` controls because
/// those already paint a hover state for free; double-tinting them
/// would just look noisy.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    let cornerRadius: CGFloat
    let tint: Color
    /// When true (default), also flip NSCursor to .pointingHand on
    /// enter and pop it on exit. Disable on chunky controls where the
    /// arrow cursor reads better than the hand (e.g. row drag
    /// affordances).
    let changesCursor: Bool

    func body(content: Content) -> some View {
        content
            .background(
                hovering ? AnyShapeStyle(tint.opacity(0.18))
                         : AnyShapeStyle(Color.clear),
                in: .rect(cornerRadius: cornerRadius),
            )
            .onHover { isHovering in
                hovering = isHovering
                guard changesCursor else { return }
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    /// Paint a subtle accent-coloured background while the cursor is
    /// over the view, and flip the cursor to a pointing-hand. Wraps
    /// `HoverHighlight` so call sites stay legible.
    ///
    ///     Button { … } label: { … }
    ///         .buttonStyle(.borderless)
    ///         .hoverHighlight()
    ///
    func hoverHighlight(
        cornerRadius: CGFloat = 5,
        tint: Color = .accentColor,
        changesCursor: Bool = true,
    ) -> some View {
        modifier(HoverHighlight(
            cornerRadius: cornerRadius,
            tint: tint,
            changesCursor: changesCursor,
        ))
    }
}
