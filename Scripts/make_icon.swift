// Renders the VeriCopy app icon (blue-teal rounded square with a bold check)
// into an .iconset and compiles it to Resources/AppIcon.icns via iconutil.
// Run:  swift Scripts/make_icon.swift

import AppKit
import Foundation

func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context

    let size = CGFloat(pixels)
    let inset = size * 0.06
    let squircle = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
        xRadius: size * 0.21, yRadius: size * 0.21
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.72, blue: 0.72, alpha: 1),
    ])?.draw(in: squircle, angle: -60)

    // Bold white checkmark
    let check = NSBezierPath()
    check.move(to: NSPoint(x: size * 0.28, y: size * 0.50))
    check.line(to: NSPoint(x: size * 0.44, y: size * 0.33))
    check.line(to: NSPoint(x: size * 0.73, y: size * 0.65))
    check.lineWidth = size * 0.095
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor.white.setStroke()
    check.stroke()

    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = projectRoot.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in entries {
    guard let png = renderPNG(pixels: pixels) else {
        FileHandle.standardError.write("Failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o",
                     projectRoot.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus == 0 ? 0 : 1)
