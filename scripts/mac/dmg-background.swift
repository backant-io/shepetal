// Renders the DMG window's background, 640 x 400 pt at 1x and 2x, into <out-dir>/background.png and
// background@2x.png (make-dmg.sh joins them with tiffutil): the brand's blush ground, the wordmark in ink, one
// Mulberry arrow from Shepetal.app (160, 200) to Applications (480, 200), and the instruction under the icons.
//   swift scripts/mac/dmg-background.swift <out-dir>
// ponytail: system serif and sans until brand/ (Newsreader, Hanken Grotesk) is public; then register those fonts here.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let blush = color(0xFAEEE8), ink = color(0x26141C), mulberry = color(0x9E3664), neutral = color(0x6C5B5E)
let w: CGFloat = 640, h: CGFloat = 400

func text(_ s: String, _ font: NSFont, _ c: NSColor, centerY: CGFloat) {
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])
    let size = a.size()
    a.draw(at: NSPoint(x: (w - size.width) / 2, y: h - centerY - size.height / 2))  // y from the top, as Finder places icons
}

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w) * scale, pixelsHigh: Int(h) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    blush.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    let serif = NSFont.systemFont(ofSize: 40).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 40) }
    text("shepetal", serif ?? .systemFont(ofSize: 40), ink, centerY: 62)
    // The arrow between the two icons (128 pt, centred at y 200 from the top).
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 248, y: h - 196))
    arrow.curve(to: NSPoint(x: 388, y: h - 196), controlPoint1: NSPoint(x: 290, y: h - 160), controlPoint2: NSPoint(x: 346, y: h - 160))
    arrow.move(to: NSPoint(x: 374, y: h - 182))
    arrow.line(to: NSPoint(x: 390, y: h - 197))
    arrow.line(to: NSPoint(x: 370, y: h - 203))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    mulberry.setStroke()
    arrow.stroke()
    text("Drag Shepetal into Applications", .systemFont(ofSize: 13, weight: .medium), neutral, centerY: 330)
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
