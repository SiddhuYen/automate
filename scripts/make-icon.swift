// Draws Automate's app icon and writes an .iconset folder (turn it into .icns with `iconutil -c icns`).
//   swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: an 824/1024 rounded square, centered.
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.62, green: 0.25, blue: 0.85, alpha: 1)])!
        .draw(in: path, angle: -60)
    // Soft top highlight.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])!
        .draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let sz = symbol.size
        symbol.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out.path)")
