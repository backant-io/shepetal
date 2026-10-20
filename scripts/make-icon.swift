// Renders the app icon: the shushing-face emoji 🤫, drawn with the system's Apple Color Emoji font,
// at every size macOS asks for (16 to 1024 px), into an .iconset that `iconutil` turns into AppIcon.icns.
// Run by scripts/make-app.sh:  swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

guard let font = NSFont(name: "Apple Color Emoji", size: 100) else {
    FileHandle.standardError.write(Data("Apple Color Emoji font not found\n".utf8))
    exit(1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: px, height: px).fill()
    // The glyph fills about 84 % of the square, like the margin of macOS app icons.
    let glyph = NSAttributedString(string: "🤫", attributes: [.font: font.withSize(CGFloat(px) * 0.84 / 1.17)])
    let bounds = glyph.boundingRect(with: NSSize(width: 10 * px, height: 10 * px), options: [.usesLineFragmentOrigin])
    let size = glyph.size()
    glyph.draw(at: NSPoint(x: (CGFloat(px) - size.width) / 2, y: (CGFloat(px) - bounds.height) / 2 - bounds.minY))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(points * scale).write(to: out.appendingPathComponent(name))
}
print("Rendered \(out.path)")
