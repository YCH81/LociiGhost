import SwiftUI
import AppKit
import LociiGhostCore

/// Draws a `FlowerPin.Design` from the discs Core hands out.
///
/// The union of overlapping filled circles is done by the fill rule,
/// not by path arithmetic: with `.nonZero`, overlapping subpaths merge
/// into one silhouette, which is precisely the chunky rounded flower
/// we want and costs nothing.
struct FlowerPinShape: Shape {
    let design: FlowerPin.Design

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let radius = min(rect.width, rect.height) / 2
        let cx = rect.midX
        let cy = rect.midY
        for disc in FlowerPin.discs(for: design) {
            let r = disc.r * radius
            p.addEllipse(in: CGRect(
                x: cx + disc.x * radius - r,
                y: cy + disc.y * radius - r,
                width: r * 2, height: r * 2,
            ))
        }
        if design.centreRadius > 0 {
            let r = design.centreRadius * radius
            p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }
        return p
    }
}

/// A flower in a category colour, with a lighter centre so it reads as
/// a flower and not a blob at pin size.
struct FlowerPinView: View {
    let design: FlowerPin.Design
    let colorHex: String
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            FlowerPinShape(design: design)
                .fill(CategorySwatch.color(colorHex))
            if design.centreRadius > 0 {
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: size * design.centreRadius * 0.9,
                           height: size * design.centreRadius * 0.9)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Renders a flower to an `NSImage` for the MKMapView marker glyph.
///
/// MKMarkerAnnotationView takes a template image and tints it itself,
/// so this draws in black with `isTemplate = true` and lets the view's
/// `markerTintColor` supply the category colour — the same hex the
/// SwiftUI path passes to `CategorySwatch`. One set of discs, one
/// colour source, two renderers.
@MainActor
enum FlowerGlyph {
    /// Rendering the same design twice a frame for 3 000 pins would be
    /// silly; MapKit reuses views but not images, so cache per design.
    /// The cache is main-actor isolated rather than guarded by a lock:
    /// the only caller is `mapView(_:viewFor:)`, which is already on
    /// the main thread, so isolation is both correct and free.
    private static var cache: [String: NSImage] = [:]

    static func image(for design: FlowerPin.Design, side: CGFloat = 20) -> NSImage {
        if let hit = cache[design.id] { return hit }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let radius = min(rect.width, rect.height) / 2
            let cx = rect.midX, cy = rect.midY
            NSColor.black.setFill()
            let path = NSBezierPath()
            for disc in FlowerPin.discs(for: design) {
                let r = disc.r * radius
                path.appendOval(in: NSRect(
                    x: cx + disc.x * radius - r,
                    y: cy + disc.y * radius - r,
                    width: r * 2, height: r * 2,
                ))
            }
            if design.centreRadius > 0 {
                let r = design.centreRadius * radius
                path.appendOval(in: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            path.windingRule = .nonZero
            path.fill()
            return true
        }
        img.isTemplate = true
        cache[design.id] = img
        return img
    }
}
