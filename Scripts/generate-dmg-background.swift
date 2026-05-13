#!/usr/bin/env swift
// Generates the DMG background image used by Scripts/make-dmg.sh.
//
// The output is a 1080×760 PNG at Scripts/dmg-assets/background.png.
// 1080×760 is exactly 2× the 540×380 Finder window content area, so
// the same image looks crisp on both regular and Retina displays
// without needing separate @1x / @2x assets.
//
// Visual:
//
//   ┌────────────────────────────────────────────┐
//   │                                            │
//   │   [ ]                            [ ]       │   ← icons
//   │  LociiGhost.app  ──────►   Applications   │
//   │                                            │
//   │       Drag LociiGhost.app to Applications  │
//   │                                            │
//   └────────────────────────────────────────────┘
//
// White background, a sage-tinted curved arrow from the .app slot
// on the left to the Applications slot on the right, and a single
// muted hint line at the bottom. No fancy logos; the .app icon and
// the standard Applications folder icon do all the heavy lifting.
//
// Run:
//   swift Scripts/generate-dmg-background.swift
//
// (Re-run only when you want to tweak the visual; the output PNG is
// checked in so a clean clone can build the DMG without this step.)

import AppKit
import Foundation

// MARK: - Output target

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let scriptDir = scriptURL.deletingLastPathComponent()
let assetsDir = scriptDir.appendingPathComponent("dmg-assets")
let outputURL = assetsDir.appendingPathComponent("background.png")
try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

// MARK: - Canvas

let width: CGFloat  = 1080
let height: CGFloat = 760

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("CGContext unavailable\n", stderr)
    exit(1)
}

// MARK: - Background

NSColor.white.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

// MARK: - Brand palette

let sage      = NSColor(red: 0.498, green: 0.639, blue: 0.537, alpha: 1.0)
let sageLight = NSColor(red: 0.498, green: 0.639, blue: 0.537, alpha: 0.35)
let mutedText = NSColor(red: 0.42,  green: 0.45,  blue: 0.48,  alpha: 1.0)

// MARK: - Arrow

// The .app and Applications icons are positioned at roughly
// (left=280, right=800, y≈480) in 1080×760 space — i.e., centred
// vertically a touch above the middle so the hint text below has
// room to breathe. The arrow runs between them at the same y.

let arrowStartX: CGFloat = 380   // just right of the .app icon
let arrowEndX:   CGFloat = 700   // just left of the Applications icon
let arrowY:      CGFloat = 480

let arrowPath = NSBezierPath()
arrowPath.move(to: NSPoint(x: arrowStartX, y: arrowY))
// Subtle upward arc to make the arrow feel less rigid. The two
// control points lift the midpoint by ~28 pt above the baseline.
arrowPath.curve(
    to: NSPoint(x: arrowEndX, y: arrowY),
    controlPoint1: NSPoint(x: arrowStartX + 80, y: arrowY + 28),
    controlPoint2: NSPoint(x: arrowEndX   - 80, y: arrowY + 28),
)
arrowPath.lineWidth = 6
arrowPath.lineCapStyle = .round
sage.setStroke()
arrowPath.stroke()

// Arrow head — solid sage triangle pointing right.
let headPath = NSBezierPath()
let headLen: CGFloat = 22
headPath.move(to: NSPoint(x: arrowEndX + headLen, y: arrowY))
headPath.line(to: NSPoint(x: arrowEndX - 4,       y: arrowY + headLen * 0.7))
headPath.line(to: NSPoint(x: arrowEndX - 4,       y: arrowY - headLen * 0.7))
headPath.close()
sage.setFill()
headPath.fill()

// MARK: - Faint guide circles behind where the icons will sit
// They reinforce "this is where the icon goes" even before macOS
// finishes laying out the Finder view.

func ghostCircle(at center: NSPoint, radius: CGFloat) {
    let r = NSRect(x: center.x - radius, y: center.y - radius,
                   width: radius * 2,    height: radius * 2)
    let path = NSBezierPath(ovalIn: r)
    sageLight.setStroke()
    path.lineWidth = 1.5
    path.setLineDash([6, 5], count: 2, phase: 0)
    path.stroke()
}

let iconRadius: CGFloat = 90
ghostCircle(at: NSPoint(x: 280, y: arrowY), radius: iconRadius)
ghostCircle(at: NSPoint(x: 800, y: arrowY), radius: iconRadius)

// MARK: - Hint text along the bottom

let hintFont = NSFont.systemFont(ofSize: 26, weight: .medium)
let hint = "Drag LociiGhost.app to Applications to install"
let hintAttrs: [NSAttributedString.Key: Any] = [
    .font:            hintFont,
    .foregroundColor: mutedText,
]
let hintSize = (hint as NSString).size(withAttributes: hintAttrs)
let hintRect = NSRect(
    x: (width - hintSize.width) / 2,
    y: 130,
    width:  hintSize.width,
    height: hintSize.height,
)
(hint as NSString).draw(in: hintRect, withAttributes: hintAttrs)

// MARK: - Write PNG

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep  = NSBitmapImageRep(data: tiff),
      let png  = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

try png.write(to: outputURL)
print("==> wrote \(outputURL.path) (\(png.count) bytes, \(Int(width))×\(Int(height)))")
