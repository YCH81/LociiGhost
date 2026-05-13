#!/usr/bin/env swift

// LociiGhost AppIcon builder.
//
// The master design lives at:
//   App/Sources/LociiGhost/Resources/AppIcon-Master.pdf
// (drop a designer-exported PDF or rename an Illustrator `.ai` to
// `.pdf` — Illustrator's native format IS PDF under the hood.)
//
// We render the master into a SQUARE bitmap at every macOS-iconset
// size, centring it with letterbox padding if the master's bounding
// box isn't 1:1 (it usually isn't — AI canvases tend to be slightly
// taller than wide, ~1024×957 in this project's reference file).
// Padding keeps the original design proportions intact; the
// alternative `-z H W` stretch from sips would squish the artwork
// by a few percent. iconutil requires every iconset member to be
// exactly square — stretching is what was crashing `iconutil` with
// "Failed to generate ICNS" before this script existed in its
// current form.
//
// Usage:
//   swift Scripts/generate-icon.swift

import AppKit
import CoreGraphics
import Foundation

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesDir = projectRoot
    .appendingPathComponent("App/Sources/LociiGhost/Resources")
let masterURL = resourcesDir.appendingPathComponent("AppIcon-Master.pdf")
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset")
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x", 1024),
]

// Background colour used for letterbox padding. Sampled to match
// the master's surrounding frame so the seam is invisible. Adjust
// if the artwork's outer background ever changes.
let padColor = CGColor(red: 0.969, green: 0.965, blue: 0.953, alpha: 1.0)  // #F7F6F3

let fm = FileManager.default

guard fm.fileExists(atPath: masterURL.path) else {
    print("Master file not found: \(masterURL.path)")
    print("Drop your designer-exported PDF (or a renamed .ai → .pdf) at")
    print("that path and re-run this script.")
    exit(1)
}

// Load the master as an NSImage. PDF and .ai-renamed-to-.pdf both
// work; NSImage handles the PDF rendering internally.
guard let master = NSImage(contentsOf: masterURL) else {
    print("Couldn't load master at \(masterURL.path)")
    exit(1)
}

// Reset the iconset folder so stale PNGs from a previous master
// can't leak into the .icns.
if fm.fileExists(atPath: iconsetDir.path) {
    try fm.removeItem(at: iconsetDir)
}
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderSquareIcon(size: Int, to fileURL: URL) throws {
    let s = CGFloat(size)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(
            domain: "icon", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "couldn't create bitmap"]
        )
    }

    // 0. macOS-style rounded-corner mask. Apple's Big Sur+ icon
    //    template uses a squircle with corner radius ≈ 22.37% of
    //    the canvas edge — Dock displays the .icns raw (no
    //    automatic masking), so the rounded corners have to be
    //    baked into each iconset PNG. Anything we paint AFTER
    //    `ctx.clip()` stays inside the squircle; pixels outside
    //    remain transparent, which is exactly what gives Dock /
    //    Finder / Launchpad the canonical app-icon shape instead
    //    of square corners.
    let cornerRadius = s * 0.2237
    let squircle = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil,
    )
    ctx.addPath(squircle)
    ctx.clip()

    // 1. Square background — matches the master's surround so the
    //    letterbox bands blend in seamlessly. The clip above means
    //    only the squircle area gets filled; the corners stay
    //    transparent.
    ctx.setFillColor(padColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // 2. Compute the fit rect — scale the master to fit fully inside
    //    the square (largest dimension hits the edge), centre on the
    //    smaller axis.
    let mw = master.size.width
    let mh = master.size.height
    let scale = min(s / mw, s / mh)
    let drawW = mw * scale
    let drawH = mh * scale
    let drawRect = CGRect(
        x: (s - drawW) / 2,
        y: (s - drawH) / 2,
        width: drawW,
        height: drawH,
    )

    // 3. Render the PDF into the rect using AppKit's draw path,
    //    which handles PDF rasterisation natively at the right
    //    resolution for this size (no aliasing from a 1024 master
    //    being downscaled — NSImage queries the PDF at the target
    //    resolution directly).
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    master.draw(
        in: drawRect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0,
    )
    NSGraphicsContext.restoreGraphicsState()

    // 4. Encode + write
    guard let cgImage = ctx.makeImage() else {
        throw NSError(
            domain: "icon", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "makeImage failed"]
        )
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "icon", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"]
        )
    }
    try pngData.write(to: fileURL, options: .atomic)
}

print("==> Rendering iconset from \(masterURL.lastPathComponent) (\(Int(master.size.width))×\(Int(master.size.height)) source)…")
for entry in iconSizes {
    let target = iconsetDir.appendingPathComponent("\(entry.name).png")
    try renderSquareIcon(size: entry.pixels, to: target)
    print("   \(entry.name).png  (\(entry.pixels)×\(entry.pixels))")
}

print("==> Running iconutil…")
let icnsProc = Process()
icnsProc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
icnsProc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try icnsProc.run()
icnsProc.waitUntilExit()
guard icnsProc.terminationStatus == 0 else {
    print("iconutil failed with status \(icnsProc.terminationStatus)")
    exit(Int32(icnsProc.terminationStatus))
}

print("==> Wrote \(icnsURL.path)")
print("Re-run package-app.sh to bundle the new icon into LociiGhost.app.")
