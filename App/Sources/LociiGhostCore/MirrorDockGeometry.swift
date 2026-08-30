import CoreGraphics

/// Which side of the LociiGhost window the mirrored phone screen is
/// glued to.
public enum MirrorDockEdge: String, Sendable, CaseIterable, Codable {
    case right
    case left
}

/// Result of one placement calculation.
///
/// Every rectangle here is in **Accessibility screen space**: origin
/// at the top-left corner of the primary display, `y` growing
/// downward. That's the space `AXPosition` / `AXSize` speak, and
/// doing the whole calculation in it keeps exactly one conversion
/// (AppKit -> AX) at the edge of the system instead of scattering
/// flips through the placement logic.
public struct MirrorDockPlacement: Sendable, Equatable {
    /// Where the mirror window should be moved to.
    public var mirrorOrigin: CGPoint
    /// Where the app window should be moved to — `nil` when it can
    /// stay exactly where the user put it, which is the common case.
    /// Non-nil only when the pair would otherwise hang off the
    /// screen edge and sliding the app across makes them both fit.
    public var appOrigin: CGPoint?
    /// False when app + gap + mirror is simply wider than the
    /// screen. We still return a placement (clamped on-screen), but
    /// the two windows will overlap, so the UI warns instead of
    /// pretending it worked.
    public var fits: Bool

    public init(mirrorOrigin: CGPoint, appOrigin: CGPoint?, fits: Bool) {
        self.mirrorOrigin = mirrorOrigin
        self.appOrigin = appOrigin
        self.fits = fits
    }
}

/// Pure geometry for the docked-mirror layout.
///
/// Split out of `MirrorDock` (which is all AppKit + Accessibility
/// side effects) so the arithmetic — the part that actually gets
/// subtly wrong on a second display sitting above-left of the
/// built-in one — can be exercised by tests without a window server.
public enum MirrorDockGeometry {
    /// Default breathing room between the two windows, in points.
    /// Small enough to read as "one unit", large enough that the
    /// mirror window's own drop shadow doesn't paint over our
    /// window's rounded corner.
    public static let defaultGap: CGFloat = 8

    /// Compute where the mirror window (and, if needed, the app
    /// window) has to sit so the mirror is flush against `edge` of
    /// the app window and both stay inside `screen`.
    ///
    /// - Parameters:
    ///   - app: current app-window frame, AX space.
    ///   - mirrorSize: the mirror window's size. Treated as fixed —
    ///     iPhone Mirroring only offers three sizes from its own
    ///     View menu and refuses `AXSize` writes on some releases,
    ///     so the layout adapts to the mirror rather than the other
    ///     way round.
    ///   - screen: the usable (menu-bar- and Dock-excluded) area of
    ///     the display the app window is on, AX space.
    ///   - edge: which side to dock on.
    ///   - gap: space between the windows.
    public static func place(
        app: CGRect,
        mirrorSize: CGSize,
        screen: CGRect,
        edge: MirrorDockEdge,
        gap: CGFloat = defaultGap,
    ) -> MirrorDockPlacement {
        let total = app.width + gap + mirrorSize.width
        let fits = total <= screen.width

        var appX = app.minX
        var movedApp = false

        if fits {
            switch edge {
            case .right:
                // Slide left only as far as needed to bring the
                // mirror's right edge back on screen.
                let overflow = (app.maxX + gap + mirrorSize.width) - screen.maxX
                if overflow > 0 {
                    appX = max(screen.minX, app.minX - overflow)
                    movedApp = true
                }
            case .left:
                let overflow = screen.minX - (app.minX - gap - mirrorSize.width)
                if overflow > 0 {
                    appX = min(screen.maxX - app.width, app.minX + overflow)
                    movedApp = true
                }
            }
        }

        let mirrorX: CGFloat
        switch edge {
        case .right: mirrorX = appX + app.width + gap
        case .left:  mirrorX = appX - gap - mirrorSize.width
        }

        // Vertical: top-align with the app window, then clamp so the
        // mirror never runs under the menu bar or below the Dock. A
        // mirror taller than the whole usable height pins to the top
        // — the phone's status bar is the half you want visible.
        var mirrorY = app.minY
        if mirrorSize.height >= screen.height {
            mirrorY = screen.minY
        } else {
            mirrorY = min(max(mirrorY, screen.minY), screen.maxY - mirrorSize.height)
        }

        // When it can't fit we still hand back an on-screen rect so
        // the mirror is reachable; `fits == false` is what the UI
        // reacts to.
        let clampedMirrorX = fits
            ? mirrorX
            : min(max(mirrorX, screen.minX), max(screen.minX, screen.maxX - mirrorSize.width))

        return MirrorDockPlacement(
            mirrorOrigin: CGPoint(x: clampedMirrorX, y: mirrorY),
            appOrigin: movedApp ? CGPoint(x: appX, y: app.minY) : nil,
            fits: fits,
        )
    }

    /// How tall we'd *like* the mirror to be, and the width that
    /// keeps the phone's aspect ratio at that height.
    ///
    /// Used for the one speculative `AXSize` write we attempt per
    /// dock session: if iPhone Mirroring honours it, the phone ends
    /// up exactly as tall as the LociiGhost window and the pair
    /// reads as a single unit. If it refuses (it does on some
    /// releases — the size is driven by its own View menu), we read
    /// back whatever it kept and lay out around that instead.
    ///
    /// Returns `nil` when the current size is degenerate, so callers
    /// never divide by zero on a window that hasn't finished
    /// materialising.
    public static func aspectFittedSize(
        current: CGSize,
        targetHeight: CGFloat,
        maxHeight: CGFloat,
    ) -> CGSize? {
        guard current.width > 1, current.height > 1, targetHeight > 1 else { return nil }
        let height = min(targetHeight, maxHeight)
        guard height > 1 else { return nil }
        let aspect = current.width / current.height
        return CGSize(width: (height * aspect).rounded(), height: height.rounded())
    }
}
