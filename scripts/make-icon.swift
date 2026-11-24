// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824pt rounded square centered on a 1024 canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(white: 1, alpha: 1),
        NSColor(red: 0.93, green: 0.93, blue: 0.92, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    let ink = NSColor(red: 0.216, green: 0.208, blue: 0.184, alpha: 1)
    // Waveform bars (audio) on the left...
    ink.setFill()
    let barWidth: CGFloat = 46 * s
    let centerY: CGFloat = 512 * s
    let heights: [CGFloat] = [150, 300, 420, 250, 340]
    for (i, h) in heights.enumerated() {
        let x = (250 + CGFloat(i) * 78) * s
        NSBezierPath(roundedRect: NSRect(x: x, y: centerY - h * s / 2, width: barWidth, height: h * s), xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    // ...becoming lines of text on the right.
    let lineWidths: [CGFloat] = [190, 150, 190, 110]
    for (i, w) in lineWidths.enumerated() {
        let y = (622 - CGFloat(i) * 72) * s
        ink.withAlphaComponent(i == 0 ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: 640 * s, y: y - 18 * s, width: w * s, height: 36 * s), xRadius: 18 * s, yRadius: 18 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
