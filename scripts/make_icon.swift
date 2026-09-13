// Renders the app icon (stacked layers + bar chart) to an .icns file.
// usage: swift scripts/make_icon.swift <output.icns> [--dev]
//   --dev adds an orange "DEV" band, so the Dev build is easy to tell apart in the Dock and app switcher.
import AppKit

let args = CommandLine.arguments.dropFirst()
let dev = args.contains("--dev")
let out = args.first { !$0.hasPrefix("--") } ?? "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: color(0x1C5CAB), ending: color(0x3987E5))!.draw(in: bg, angle: 90)

    // Stacked layers (the vSphere estate)
    for i in 0..<3 {
        let y = s * (0.30 + CGFloat(i) * 0.095)
        let layer = NSBezierPath()
        let cx = s * 0.40, w = s * 0.22, h = s * 0.075
        layer.move(to: NSPoint(x: cx - w, y: y))
        layer.line(to: NSPoint(x: cx, y: y - h))
        layer.line(to: NSPoint(x: cx + w, y: y))
        layer.line(to: NSPoint(x: cx, y: y + h))
        layer.close()
        color(0xFFFFFF, i == 2 ? 1 : 0.55 + CGFloat(i) * 0.15).setFill()
        layer.fill()
    }
    // Bar chart (the analysis)
    let bars: [CGFloat] = [0.16, 0.26, 0.36]
    for (i, h) in bars.enumerated() {
        let r = NSRect(x: s * (0.64 + CGFloat(i) * 0.075), y: s * 0.25, width: s * 0.052, height: s * h)
        (i == 2 ? color(0xFAB219) : color(0xFFFFFF, 0.9)).setFill()
        NSBezierPath(roundedRect: r, xRadius: s * 0.012, yRadius: s * 0.012).fill()
    }

    // Dev build: an orange band across the bottom of the tile, labelled DEV where it's large enough to read.
    if dev {
        NSGraphicsContext.saveGraphicsState()
        bg.addClip()
        let band = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s * 0.2)
        color(0xE8590C).setFill()
        band.fill()
        if px >= 32 {
            let font = NSFont.systemFont(ofSize: s * 0.13, weight: .heavy)
            let text = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: s * 0.01])
            let size = text.size()
            text.draw(at: NSPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2 + s * 0.004))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
if task.terminationStatus != 0 { fatalError("iconutil failed") }
print("wrote \(out)")
