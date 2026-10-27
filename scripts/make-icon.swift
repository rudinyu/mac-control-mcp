// Draws the MacControl app icon and writes App/AppIcon.icns.
//   swift scripts/make-icon.swift
// The artwork is drawn from plain shapes (no SF Symbols, which Apple does not license for app icons):
// a blue rounded square, a mouse pointer for screen control, and a ">_" prompt for the sandbox.

import AppKit

let project = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> Data {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let s = size / 1024 // artwork is laid out on a 1024-point canvas

    // macOS icon grid: an 824-point rounded square centred in the canvas, leaving room for the shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.16, green: 0.31, blue: 0.86, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.25, green: 0.52, blue: 1.0, alpha: 1),
                        NSColor(calibratedRed: 0.31, green: 0.20, blue: 0.80, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Terminal panel in the lower left.
    let panel = NSBezierPath(roundedRect: NSRect(x: 190 * s, y: 190 * s, width: 470 * s, height: 330 * s), xRadius: 56 * s, yRadius: 56 * s)
    NSColor(calibratedWhite: 0.06, alpha: 0.55).setFill()
    panel.fill()
    let prompt = NSBezierPath()
    prompt.lineWidth = 46 * s
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.move(to: NSPoint(x: 270 * s, y: 430 * s))
    prompt.line(to: NSPoint(x: 360 * s, y: 355 * s))
    prompt.line(to: NSPoint(x: 270 * s, y: 280 * s))
    NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.70, alpha: 1).setStroke()
    prompt.stroke()
    let cursorBar = NSBezierPath(roundedRect: NSRect(x: 405 * s, y: 258 * s, width: 160 * s, height: 44 * s), xRadius: 22 * s, yRadius: 22 * s)
    NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.70, alpha: 1).setFill()
    cursorBar.fill()

    // Mouse pointer in the upper right, overlapping the panel.
    let arrow = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [(470, 830), (470, 380), (575, 480), (650, 320), (725, 352), (650, 512), (790, 512)]
    arrow.move(to: NSPoint(x: points[0].0 * s, y: points[0].1 * s))
    for point in points.dropFirst() { arrow.line(to: NSPoint(x: point.0 * s, y: point.1 * s)) }
    arrow.close()
    arrow.lineJoinStyle = .round
    let arrowShadow = NSShadow()
    arrowShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    arrowShadow.shadowBlurRadius = 18 * s
    arrowShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    NSGraphicsContext.saveGraphicsState()
    arrowShadow.set()
    NSColor.white.setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
    arrow.lineWidth = 22 * s
    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.35, alpha: 1).setStroke()
    arrow.stroke()
    NSColor.white.setFill()
    arrow.fill()

    NSGraphicsContext.restoreGraphicsState()
    return image.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try draw(CGFloat(points)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try draw(CGFloat(points * 2)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = project.appendingPathComponent("App/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
