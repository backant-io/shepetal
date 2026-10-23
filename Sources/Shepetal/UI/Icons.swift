// Lucide icons (UI/Assets/Icons, ISC, release pinned in UI/Assets/SOURCES.md): one icon set on every platform.
// Each SVG is read once into a path on its 24 pt grid and stroked at 1.5 pt with round caps and joins in the
// current foreground style, like a template image. 16 pt in rows, menus, buttons and the sidebar; 20 in toolbars.
import SwiftUI

/// The bundled icons, by their Lucide names.
enum SHIconName: String, CaseIterable, Sendable {
    case badgeCheck = "badge-check"
    case bookA = "book-a"
    case calendar
    case captions
    case check
    case chevronDown = "chevron-down"
    case chevronRight = "chevron-right"
    case circle
    case circleAlert = "circle-alert"
    case circleX = "circle-x"
    case clockAlert = "clock-alert"
    case copy
    case dot
    case ellipsis
    case folder
    case folderPlus = "folder-plus"
    case house
    case info
    case pencil
    case pin
    case pinOff = "pin-off"
    case plus
    case rotateCcwClock = "rotate-ccw-clock"
    case search
    case settings
    case share
    case star
    case textAlignStart = "text-align-start"
    case textQuote = "text-quote"
    case trash
    case triangleAlert = "triangle-alert"
    case user
    case users
    case x

    /// The icon on its 24 x 24 grid, read from the bundled SVG once.
    var path: Path { SHIconCache.path(self) }
}

/// An icon drawn at `size` with a 1.5 pt stroke in the foreground style. Decorative unless given a label:
/// an icon-only control names itself with `.accessibilityLabel` on the control.
struct SHIcon: View {
    let name: SHIconName
    var size: CGFloat = 16

    init(_ name: SHIconName, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        SHIconShape(path: name.path)
            .stroke(style: StrokeStyle(lineWidth: SHIconShape.stroke, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The 24 pt grid scaled into the frame; the stroke stays 1.5 pt at every size.
struct SHIconShape: Shape {
    static let grid: CGFloat = 24
    static let stroke: CGFloat = 1.5
    let path: Path

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / Self.grid
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: s, y: s))
    }
}

enum SHIconCache {
    nonisolated(unsafe) private static var cache: [SHIconName: Path] = [:]
    private static let lock = NSLock()

    static func path(_ name: SHIconName) -> Path {
        lock.lock()
        defer { lock.unlock() }
        if let p = cache[name] { return p }
        let url = SHAssets.url("Icons/\(name.rawValue).svg")
        guard let data = try? Data(contentsOf: url), let p = SVGIcon.path(data) else {
            fatalError("shepetal UI: icon \(name.rawValue) is missing or unreadable at \(url.path)")
        }
        cache[name] = p
        return p
    }
}

/// The SVG subset Lucide uses: path, circle, ellipse, line, rect (with rx/ry), polyline and polygon, in user units.
enum SVGIcon {
    static func path(_ data: Data) -> Path? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.ok else { return nil }
        return reader.path.isEmpty ? nil : reader.path
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var path = Path()
        var ok = true

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            func n(_ key: String) -> CGFloat { a[key].flatMap { Double($0) }.map { CGFloat($0) } ?? 0 }
            switch element {
            case "path":
                guard let d = a["d"], let p = SVGPathData.parse(d) else { ok = false; return }
                path.addPath(p)
            case "circle":
                let r = n("r")
                path.addEllipse(in: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r))
            case "ellipse":
                path.addEllipse(in: CGRect(x: n("cx") - n("rx"), y: n("cy") - n("ry"), width: 2 * n("rx"), height: 2 * n("ry")))
            case "line":
                path.move(to: CGPoint(x: n("x1"), y: n("y1")))
                path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
            case "rect":
                let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
                let rx = a["rx"] != nil ? n("rx") : n("ry"), ry = a["ry"] != nil ? n("ry") : rx
                if rx > 0 || ry > 0 {
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: rx, height: ry))
                } else {
                    path.addRect(rect)
                }
            case "polyline", "polygon":
                let v = SVGPathData.numbers(a["points"] ?? "")
                guard v.count >= 4, v.count % 2 == 0 else { ok = false; return }
                path.move(to: CGPoint(x: v[0], y: v[1]))
                for i in stride(from: 2, to: v.count, by: 2) { path.addLine(to: CGPoint(x: v[i], y: v[i + 1])) }
                if element == "polygon" { path.closeSubpath() }
            case "svg", "g", "title", "desc":
                break
            default:
                ok = false  // something Lucide does not draw with: refuse rather than drop it
            }
        }
    }
}

/// SVG path data (M L H V C S Q T A Z, absolute and relative) to a Path. Arcs become cubic curves.
enum SVGPathData {
    static func parse(_ d: String) -> Path? {
        var s = Scanner(Array(d.utf8))
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?  // for S and T
        var lastCommand: UInt8 = 0
        while true {
            s.skipSeparators()
            guard let c = s.peek() else { break }
            var command: UInt8
            if isCommand(c) {
                command = c
                s.index += 1
            } else {
                // Repeated parameters: a moveto's extra pairs are linetos.
                guard lastCommand != 0, lastCommand != UInt8(ascii: "Z"), lastCommand != UInt8(ascii: "z") else { return nil }
                command = lastCommand == UInt8(ascii: "M") ? UInt8(ascii: "L") : lastCommand == UInt8(ascii: "m") ? UInt8(ascii: "l") : lastCommand
            }
            let relative = command >= UInt8(ascii: "a")
            let upper = relative ? command - 32 : command
            func point() -> CGPoint? {
                guard let x = s.number(), let y = s.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            var control: CGPoint?
            switch upper {
            case UInt8(ascii: "M"):
                guard let p = point() else { return nil }
                path.move(to: p)
                current = p
                start = p
            case UInt8(ascii: "L"):
                guard let p = point() else { return nil }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "H"):
                guard let x = s.number() else { return nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "V"):
                guard let y = s.number() else { return nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "C"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                control = c2
                current = p
            case UInt8(ascii: "S"):
                let c1 = reflect(lastControl, current, smooth: "CcSs", lastCommand)
                guard let c2 = point(), let p = point() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                control = c2
                current = p
            case UInt8(ascii: "Q"):
                guard let c1 = point(), let p = point() else { return nil }
                path.addQuadCurve(to: p, control: c1)
                control = c1
                current = p
            case UInt8(ascii: "T"):
                let c1 = reflect(lastControl, current, smooth: "QqTt", lastCommand)
                guard let p = point() else { return nil }
                path.addQuadCurve(to: p, control: c1)
                control = c1
                current = p
            case UInt8(ascii: "A"):
                guard let rx = s.number(), let ry = s.number(), let rotation = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let p = point() else { return nil }
                arc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "Z"):
                path.closeSubpath()
                current = start
            default:
                return nil
            }
            lastControl = control
            lastCommand = command
        }
        return path
    }

    static func numbers(_ text: String) -> [CGFloat] {
        var s = Scanner(Array(text.utf8))
        var out: [CGFloat] = []
        while let n = s.number() { out.append(n) }
        return out
    }

    private static func isCommand(_ c: UInt8) -> Bool {
        "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c)
    }

    private static func reflect(_ control: CGPoint?, _ current: CGPoint, smooth: String, _ last: UInt8) -> CGPoint {
        guard let control, smooth.utf8.contains(last) else { return current }
        return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
    }

    /// SVG's endpoint arc (implementation notes F.6.5) as cubic curves of at most 90 degrees each.
    static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                    rotation: CGFloat, large: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = den == 0 ? 0 : (max(0, num) / den).squareRoot()
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        func onEllipse(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        var a = theta1
        for i in 0..<segments {
            let b = a + step
            let pa = onEllipse(a), pb = i == segments - 1 ? p1 : onEllipse(b)
            let da = derivative(a), db = derivative(b)
            path.addCurve(to: pb, control1: CGPoint(x: pa.x + t * da.x, y: pa.y + t * da.y),
                          control2: CGPoint(x: pb.x - t * db.x, y: pb.y - t * db.y))
            a = b
        }
    }

    struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipSeparators() {
            while let c = peek(), c == 0x20 || c == 0x2C || c == 0x09 || c == 0x0A || c == 0x0D { index += 1 }
        }

        /// An arc flag: a single 0 or 1, which may run into the next number ("a1 1 0 01.5 2").
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let c = peek(), c == UInt8(ascii: "0") || c == UInt8(ascii: "1") else { return nil }
            index += 1
            return c == UInt8(ascii: "1")
        }

        /// A number: sign, digits, one dot, exponent. ".5.5" is two numbers, "1-2" is two.
        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if let c = peek(), c == UInt8(ascii: "-") || c == UInt8(ascii: "+") { index += 1 }
            var digits = false, dot = false
            while let c = peek() {
                if c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") {
                    digits = true
                } else if c == UInt8(ascii: "."), !dot {
                    dot = true
                } else {
                    break
                }
                index += 1
            }
            if digits, let c = peek(), c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                var j = index + 1
                if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
                if j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") {
                    index = j
                    while let d = peek(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") { index += 1 }
                }
            }
            guard digits, let text = String(bytes: bytes[begin..<index], encoding: .ascii), let v = Double(text) else {
                index = begin
                return nil
            }
            return CGFloat(v)
        }
    }
}
