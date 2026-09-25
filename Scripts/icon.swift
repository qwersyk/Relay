import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let n = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(n) / 1024)
        (transform as NSAffineTransform).concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(calibratedRed: 0.19, green: 0.27, blue: 0.30, alpha: 1),
                   ending: NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.14, alpha: 1))!.draw(in: tile, angle: -90)
        let rotation = NSAffineTransform()
        rotation.translateX(by: 512, yBy: 512); rotation.rotate(byDegrees: 38); rotation.translateX(by: -512, yBy: -512); rotation.concat()
        let first = NSBezierPath(roundedRect: NSRect(x: 232, y: 382, width: 350, height: 260), xRadius: 130, yRadius: 130)
        first.lineWidth = 66
        NSColor(calibratedRed: 0.68, green: 0.87, blue: 0.82, alpha: 1).setStroke(); first.stroke()
        let second = NSBezierPath(roundedRect: NSRect(x: 442, y: 382, width: 350, height: 260), xRadius: 130, yRadius: 130)
        second.lineWidth = 100
        NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.21, alpha: 1).setStroke(); second.stroke()
        second.lineWidth = 66; NSColor(calibratedWhite: 0.98, alpha: 1).setStroke(); second.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
