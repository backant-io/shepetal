import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import Shepetal

/// The shepetal UI foundation (Sources/Shepetal/UI) against design/ui: every Swift token equals tokens.json (read
/// here on its own, so a hand edit to Tokens.swift or a tokens.json change without scripts/ui/gen_tokens.py fails),
/// the bundled families resolve to themselves, and every bundled Lucide icon parses onto its 24 pt grid.
final class UITokenTests: XCTestCase {
    private var tokens: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("design/ui/tokens.json")
        tokens = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func list(_ group: String) throws -> [[String: Any]] {
        let g = try XCTUnwrap(tokens[group] as? [String: Any], group)
        return try XCTUnwrap(g["tokens"] as? [[String: Any]], group)
    }

    private static func rgba(_ hex: String) throws -> UInt32 {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 6 { h += "FF" }
        return try XCTUnwrap(UInt32(h, radix: 16), hex)
    }

    private static func px(_ value: String) throws -> CGFloat {
        CGFloat(try XCTUnwrap(Double(value.replacingOccurrences(of: "px", with: "")), value))
    }

    func testColorsMatchTokensJSON() throws {
        let all = try list("color")
        var ramp: [String: String] = [:]
        for t in all { if let v = t["value"] as? String, !v.hasPrefix("{") { ramp[t["name"] as! String] = v } }
        func resolve(_ v: String) throws -> UInt32 {
            if v.hasPrefix("{") { return try Self.rgba(try XCTUnwrap(ramp[String(v.dropFirst().dropLast())], v)) }
            return try Self.rgba(v)
        }
        let swift = Dictionary(uniqueKeysWithValues: SHTokens.colors.map { ($0.name, $0) })
        XCTAssertEqual(swift.count, all.count, "Tokens.swift and tokens.json have different colors")
        for t in all {
            let name = t["name"] as! String
            let s = try XCTUnwrap(swift[name], "\(name) is missing from Tokens.swift")
            let light: UInt32, dark: UInt32
            if let v = t["value"] as? String {
                light = try resolve(v); dark = light
            } else {
                let v = try XCTUnwrap(t["value"] as? [String: String])
                light = try resolve(try XCTUnwrap(v["light"])); dark = try resolve(try XCTUnwrap(v["dark"]))
            }
            XCTAssertEqual(s.light, light, "\(name) Concrete")
            XCTAssertEqual(s.dark, dark, "\(name) Night")
        }
    }

    func testScalarsMatchTokensJSON() throws {
        let groups: [(String, [(name: String, value: CGFloat)])] = [
            ("spacing", SHTokens.space), ("radius", SHTokens.radius), ("travel", SHTokens.travel), ("size", SHTokens.size),
        ]
        for (group, swift) in groups {
            let json = try list(group).filter { ($0["value"] as! String).hasSuffix("px") }
            XCTAssertEqual(swift.map { $0.name }, json.map { $0["name"] as! String }, group)
            for (s, j) in zip(swift, json) { XCTAssertEqual(s.value, try Self.px(j["value"] as! String), s.name) }
        }
        // The one size with no point value.
        XCTAssertEqual(try list("size").filter { !($0["value"] as! String).hasSuffix("px") }.map { $0["name"] as! String },
                       ["sh-measure"])
        let layers = try list("layer")
        XCTAssertEqual(SHTokens.layer.map { $0.name }, layers.map { $0["name"] as! String })
        for (s, j) in zip(SHTokens.layer, layers) { XCTAssertEqual(s.value, Int(j["value"] as! String), s.name) }
        let durations = try list("duration")
        XCTAssertEqual(SHTokens.duration.map { $0.name }, durations.map { $0["name"] as! String })
        for (s, j) in zip(SHTokens.duration, durations) {
            let ms = Double((j["value"] as! String).replacingOccurrences(of: "ms", with: ""))!
            XCTAssertEqual(s.value, ms / 1000, accuracy: 1e-9, s.name)
        }
        let easings = try list("easing")
        XCTAssertEqual(SHTokens.easing.map { $0.name }, easings.map { $0["name"] as! String })
        for (s, j) in zip(SHTokens.easing, easings) {
            let v = (j["value"] as! String).replacingOccurrences(of: "cubic-bezier(", with: "").replacingOccurrences(of: ")", with: "")
                .split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces))! }
            XCTAssertEqual([s.value.x1, s.value.y1, s.value.x2, s.value.y2], v, s.name)
        }
    }

    /// box-shadow, parsed here independently of the generator: [inset] x y [blur [spread]] color.
    private static func shadow(_ css: String) throws -> [SHShadowLayer] {
        var layers: [SHShadowLayer] = []
        var depth = 0, current = ""
        var parts: [String] = []
        for ch in css {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == ",", depth == 0 { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        for part in parts {
            var words = part.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            let inset = words.first == "inset"
            if inset { words.removeFirst() }
            var lengths: [CGFloat] = []
            while let w = words.first, let v = Double(w.replacingOccurrences(of: "px", with: "")) {
                lengths.append(CGFloat(v)); words.removeFirst()
            }
            while lengths.count < 4 { lengths.append(0) }
            let color = words.joined(separator: " ")
            let rgba: UInt32
            if color.hasPrefix("#") {
                rgba = try Self.rgba(color)
            } else {
                let c = color.replacingOccurrences(of: "rgba(", with: "").replacingOccurrences(of: ")", with: "")
                    .split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces))! }
                XCTAssertEqual(c.count, 4, color)
                rgba = UInt32(c[0]) << 24 | UInt32(c[1]) << 16 | UInt32(c[2]) << 8 | UInt32((c[3] * 255).rounded())
            }
            layers.append(SHShadowLayer(inset: inset, x: lengths[0], y: lengths[1], blur: lengths[2], spread: lengths[3], rgba: rgba))
        }
        return layers
    }

    func testShadowsMatchTokensJSON() throws {
        let json = try list("shadow")
        XCTAssertEqual(SHTokens.shadows.map(\.name), json.map { $0["name"] as! String })
        for (s, j) in zip(SHTokens.shadows, json) {
            let v = try XCTUnwrap(j["value"] as? [String: String])
            XCTAssertEqual(s.light, try Self.shadow(try XCTUnwrap(v["light"])), "\(s.name) Concrete")
            XCTAssertEqual(s.dark, try Self.shadow(try XCTUnwrap(v["dark"])), "\(s.name) Night")
        }
    }

    func testTypeStylesMatchTokensJSON() throws {
        let type = try XCTUnwrap(tokens["type"] as? [String: Any])
        let groups = try XCTUnwrap(type["groups"] as? [[String: Any]])
        var expected: [(family: String, style: [String: Any])] = []
        for g in groups {
            for s in try XCTUnwrap(g["styles"] as? [[String: Any]]) { expected.append((g["family"] as! String, s)) }
        }
        XCTAssertEqual(SHTokens.textStyles.map(\.name), expected.map { $0.style["name"] as! String })
        let families: [String: SHFontFamily] = ["ui": .ui, "mono": .mono, "serif": .serif]
        for (s, e) in zip(SHTokens.textStyles, expected) {
            let size = try Self.px(e.style["fontSize"] as! String)
            XCTAssertEqual(s.family, families[e.family], s.name)
            XCTAssertEqual(s.size, size, s.name)
            if let lh = e.style["lineHeight"] as? String {
                XCTAssertEqual(s.lineHeight, try Self.px(lh), s.name)
            } else {
                XCTAssertEqual(s.lineHeight, size * CGFloat(e.style["lineHeight"] as! Double), accuracy: 0.001, s.name)
            }
            XCTAssertEqual(s.weight, CGFloat(e.style["fontWeight"] as! Int), s.name)
            let tracking = (e.style["letterSpacing"] as? String).map { Double($0.replacingOccurrences(of: "em", with: ""))! } ?? 0
            XCTAssertEqual(Double(s.tracking), tracking, accuracy: 1e-9, s.name)
            XCTAssertEqual(s.italic, e.style["fontStyle"] as? String == "italic", s.name)
        }
        // The app scale never goes below weight 420 or 11 pt.
        for s in SHTokens.textStyles where s.name.hasPrefix("app-") {
            XCTAssertGreaterThanOrEqual(s.weight, 420, s.name)
            XCTAssertGreaterThanOrEqual(s.size, 11, s.name)
        }
    }

    /// A semantic color follows the appearance it is drawn in.
    func testDynamicColorsFollowTheAppearance() throws {
        func drawn(_ c: SHColor, _ name: NSAppearance.Name) throws -> NSColor {
            var out: NSColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance { out = c.nsColor.usingColorSpace(.sRGB) }
            return try XCTUnwrap(out)
        }
        for c in [SH.bg, SH.text, SH.accent, SH.border] {
            for (name, value) in [(NSAppearance.Name.aqua, c.light), (.darkAqua, c.dark)] {
                let n = try drawn(c, name)
                XCTAssertEqual(UInt32((n.redComponent * 255).rounded()), value >> 24 & 0xFF, "\(c.name) \(name.rawValue)")
                XCTAssertEqual(UInt32((n.alphaComponent * 255).rounded()), value & 0xFF, "\(c.name) \(name.rawValue)")
            }
        }
    }
}

final class UIFontTests: XCTestCase {
    /// The bundled files register and resolve to their own families; a style never falls back to a system face.
    func testFamiliesResolve() throws {
        let result = SHFonts.register()
        for family in SHFontFamily.allCases {
            XCTAssertEqual(result[family], true, "\(family.rawValue) did not register")
            let byName = CTFontCreateWithName(family.rawValue as CFString, 14, nil)
            XCTAssertEqual(CTFontCopyFamilyName(byName) as String, family.rawValue, "a lookup by name falls back")
            let built = SHFonts.ctFont(family, size: 14, weight: 480)
            XCTAssertEqual(CTFontCopyFamilyName(built) as String, family.rawValue)
            let url = try XCTUnwrap(CTFontCopyAttribute(built, kCTFontURLAttribute) as? URL)
            XCTAssertTrue(url.path.hasSuffix(family.file), "\(family.rawValue) comes from \(url.path)")
        }
        for style in SHTokens.textStyles {
            XCTAssertEqual(CTFontCopyFamilyName(style.ctFont) as String, style.family.rawValue, style.name)
        }
        XCTAssertTrue(CTFontGetSymbolicTraits(SH.wordmark.ctFont).contains(.traitItalic), "the serif is the italic")
    }

    /// The variable weight is applied (Archivo 480 for app-body, 560 for app-strong) and figures are tabular.
    func testWeightsAndTabularFigures() throws {
        let wght = SHFonts.axis("wght")
        for style in [SH.appBody, SH.appStrong, SH.appTitle] {
            let variation = try XCTUnwrap(CTFontCopyVariation(style.ctFont) as? [NSNumber: NSNumber], style.name)
            XCTAssertEqual(variation[wght]?.doubleValue ?? 0, Double(style.weight), accuracy: 0.5, style.name)
        }
        let font = SH.appBody.nsFont
        let widths = "0123456789".map { ch -> CGFloat in
            NSAttributedString(string: String(ch), attributes: [.font: font]).size().width
        }
        XCTAssertEqual(Set(widths.map { ($0 * 100).rounded() }).count, 1, "figures are not tabular: \(widths)")
    }
}

final class UIIconTests: XCTestCase {
    func testEveryIconParsesOntoItsGrid() throws {
        for name in SHIconName.allCases {
            let box = name.path.cgPath.boundingBoxOfPath
            XCTAssertFalse(box.isEmpty, name.rawValue)
            XCTAssertTrue(CGRect(x: -0.5, y: -0.5, width: 25, height: 25).contains(box), "\(name.rawValue) \(box)")
        }
    }

    func testEveryBundledSVGHasACase() throws {
        let files = try FileManager.default.contentsOfDirectory(at: SHAssets.url("Icons"), includingPropertiesForKeys: nil)
        let svgs = Set(files.filter { $0.pathExtension == "svg" }.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(svgs, Set(SHIconName.allCases.map(\.rawValue)))
        let license = try String(contentsOf: SHAssets.url("Icons/LICENSE.txt"), encoding: .utf8)
        XCTAssertTrue(license.hasPrefix("ISC License"))
    }

    func testPathData() throws {
        // A half circle above the x axis, relative commands, numbers that run together.
        let arc = try XCTUnwrap(SVGPathData.parse("M0 0A10 10 0 0 1 20 0"))
        let box = arc.cgPath.boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 20, accuracy: 0.01)
        XCTAssertEqual(box.minY, -10, accuracy: 0.05)
        XCTAssertEqual(box.maxY, 0, accuracy: 0.01)
        let rel = try XCTUnwrap(SVGPathData.parse("m2 3h4v5h-4z"))
        XCTAssertEqual(rel.cgPath.boundingBoxOfPath, CGRect(x: 2, y: 3, width: 4, height: 5))
        let packed = try XCTUnwrap(SVGPathData.parse("M1.5.5l.5-1.5"))
        XCTAssertEqual(packed.cgPath.boundingBoxOfPath, CGRect(x: 1.5, y: -1, width: 0.5, height: 1.5))
        XCTAssertNil(SVGPathData.parse("M0 0 X 1 1"))
    }

    func testAssetsAndLicensesShip() throws {
        for path in ["Fonts/Archivo/OFL.txt", "Fonts/FragmentMono/OFL.txt", "Fonts/BodoniModa/OFL.txt",
                     "emoji-NOTICE.txt", "emoji-LICENSE-Apache-2.0.txt", "shush.svg", "SOURCES.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: SHAssets.url(path).path), path)
        }
        XCTAssertEqual(SHIndicator.shush.representations.first?.pixelsWide, 256)
    }
}

@MainActor
final class UIComponentTests: XCTestCase {
    /// The Mac shows a shortcut as one cap, symbol first; Windows and Linux one cap per key with a plus.
    func testKbdFollowsThePlatform() {
        XCTAssertEqual(SHKbd(["⌘", "V"]).caps, ["⌘V"])
        XCTAssertEqual(SHKbd(["Ctrl", "V"], os: .windows).caps, ["Ctrl", "V"])
        XCTAssertEqual(SHKbd("fn", signal: true).caps, ["fn"])
    }

    /// Each indicator state is named in words.
    func testIndicatorStatesHaveNames() {
        XCTAssertEqual([SHIndicator.State.recording, .handsFree, .writing, .note("Mic is off.")].map(\.name),
                       ["Recording", "Hands-free", "Writing", "A note"])
    }

    /// The Gallery lays out in both themes without a window on screen.
    func testGalleryRenders() throws {
        _ = NSApplication.shared
        let window = SHGallery.window()
        window.contentView?.layoutSubtreeIfNeeded()
        let size = try XCTUnwrap(window.contentView?.fittingSize)
        XCTAssertGreaterThan(size.height, 400)
        XCTAssertFalse(window.isVisible)
    }
}
