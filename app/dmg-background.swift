// Draws the DMG window's background: the app icon's gray gradient with an arrow from the app (left) to
// Applications (right). app/package.sh runs it and combines the 1x and 2x images into one TIFF, which Finder
// picks from by the screen's scale.
// Usage: swift app/dmg-background.swift <output directory>; writes background.png and background@2x.png
// The size and icon centers must match the layout in app/package.sh (640 x 400 points, icons at y 170 from the top).
import AppKit

let size = NSSize(width: 640, height: 400)
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Mid grays, like the app icon's fill; over a background picture Finder draws the icon labels black, in dark
    // mode too, and they stay readable here
    NSGradient(starting: NSColor(white: 0.60, alpha: 1), ending: NSColor(white: 0.44, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Between the two icons (centers at x 170 and 470), on their center line; AppKit's y runs up
    let y = size.height - 170
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 268, y: y))
    arrow.line(to: NSPoint(x: 372, y: y))
    arrow.move(to: NSPoint(x: 354, y: y + 16))
    arrow.line(to: NSPoint(x: 374, y: y))
    arrow.line(to: NSPoint(x: 354, y: y - 16))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(white: 1, alpha: 0.75).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
