// shepetal UI type: Archivo for everything you read and operate, Fragment Mono for labels, keys and code, Bodoni
// Moda italic for the name and words just spoken. The font files ship in the app (UI/Assets/Fonts, SIL OFL) and
// are registered at launch; a style is built from the registered file itself, so it never falls back to a system
// face. Figures are tabular everywhere.
import AppKit
import CoreText
import SwiftUI

/// UI/Assets inside the app's resource bundle: make-app.sh copies SwiftPM's bundles into Contents/Resources,
/// where Bundle.module does not look, so that is tried first (as MeetingSummarizer does).
enum SHAssets {
    static let root: URL = {
        let name = "Shepetal_Shepetal.bundle"
        if let r = Bundle.main.resourceURL, let b = Bundle(url: r.appendingPathComponent(name)),
           let url = b.url(forResource: "Assets", withExtension: nil) {
            return url
        }
        guard let url = Bundle.module.url(forResource: "Assets", withExtension: nil) else {
            fatalError("shepetal UI: the Assets folder is missing from \(name)")
        }
        return url
    }()

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }
}

enum SHFontFamily: String, CaseIterable, Sendable {
    case ui = "Archivo"
    case mono = "Fragment Mono"
    case serif = "Bodoni Moda"

    /// The bundled file, relative to UI/Assets.
    var file: String {
        switch self {
        case .ui: "Fonts/Archivo/Archivo.ttf"
        case .mono: "Fonts/FragmentMono/FragmentMono-Regular.ttf"
        case .serif: "Fonts/BodoniModa/BodoniModa-Italic.ttf"
        }
    }
}

enum SHFonts {
    /// Registers the three families for this process. Called once at launch; safe to call again.
    @discardableResult
    static func register() -> [SHFontFamily: Bool] {
        lock.lock()
        defer { lock.unlock() }
        if let done = registered { return done }
        var result: [SHFontFamily: Bool] = [:]
        for family in SHFontFamily.allCases {
            var error: Unmanaged<CFError>?
            let url = SHAssets.url(family.file) as CFURL
            let ok = CTFontManagerRegisterFontsForURL(url, .process, &error)
            // Already registered (a second register in tests) is fine: the face is there.
            let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) }
            result[family] = ok || code == CTFontManagerError.alreadyRegistered.rawValue
            if result[family] != true { NSLog("shepetal UI: could not register %@ (error %ld)", family.rawValue, code ?? -1) }
        }
        registered = result
        return result
    }

    nonisolated(unsafe) private static var registered: [SHFontFamily: Bool]?
    private static let lock = NSLock()

    /// The face from the bundled file (never a lookup by name, which could land on a system font).
    static func descriptor(_ family: SHFontFamily) -> CTFontDescriptor {
        if let d = descriptors[family] { return d }
        fatalError("shepetal UI: \(family.rawValue) is not in the app bundle (\(family.file))")
    }

    private static let descriptors: [SHFontFamily: CTFontDescriptor] = {
        register()
        var out: [SHFontFamily: CTFontDescriptor] = [:]
        for family in SHFontFamily.allCases {
            let all = CTFontManagerCreateFontDescriptorsFromURL(SHAssets.url(family.file) as CFURL) as? [CTFontDescriptor]
            out[family] = all?.first
        }
        return out
    }()

    /// A CTFont at `size` with the variable axes set (wght, and opsz for the serif) and tabular figures on.
    static func ctFont(_ family: SHFontFamily, size: CGFloat, weight: CGFloat) -> CTFont {
        var variation: [NSNumber: NSNumber] = [axis("wght"): NSNumber(value: Double(weight))]
        if family == .ui { variation[axis("wdth")] = 100 }
        if family == .serif { variation[axis("opsz")] = NSNumber(value: Double(min(max(size, 6), 96))) }
        var attributes: [CFString: Any] = [
            kCTFontFeatureSettingsAttribute: [[kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1] as [CFString: Any]],
        ]
        if family != .mono { attributes[kCTFontVariationAttribute] = variation }  // Fragment Mono is a static face
        let d = CTFontDescriptorCreateCopyWithAttributes(descriptor(family), attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(d, size, nil)
    }

    /// An OpenType axis tag as Core Text's variation key.
    static func axis(_ tag: String) -> NSNumber {
        NSNumber(value: tag.unicodeScalars.reduce(UInt32(0)) { $0 << 8 | $1.value })
    }
}

/// A type style from tokens.json: size and line height in points, weight on the variable axis, tracking in em.
struct SHTextStyle: Sendable {
    let name: String
    let family: SHFontFamily
    let size: CGFloat
    let lineHeight: CGFloat
    let weight: CGFloat
    let tracking: CGFloat
    let italic: Bool

    init(_ name: String, family: SHFontFamily, size: CGFloat, lineHeight: CGFloat, weight: CGFloat, tracking: CGFloat,
         italic: Bool) {
        self.name = name
        self.family = family
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.tracking = tracking
        self.italic = italic
    }

    /// The same style at another size or weight (a sm keycap's 13 pt label).
    func with(size: CGFloat? = nil, weight: CGFloat? = nil) -> SHTextStyle {
        SHTextStyle(name, family: family, size: size ?? self.size, lineHeight: lineHeight, weight: weight ?? self.weight,
                    tracking: tracking, italic: italic)
    }

    var ctFont: CTFont { SHFonts.ctFont(family, size: size, weight: weight) }
    var font: Font { Font(ctFont) }
    var nsFont: NSFont { ctFont as NSFont }
    /// Letter spacing in points.
    var kerning: CGFloat { tracking * size }
    /// What SwiftUI adds between lines to reach the style's line height.
    var lineSpacing: CGFloat {
        let f = ctFont
        return max(0, lineHeight - (CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)))
    }
}

extension View {
    /// Sets a type style: the bundled face, tracking and line height. `Text("History").shText(SH.appTitle)`.
    func shText(_ style: SHTextStyle) -> some View {
        font(style.font).tracking(style.kerning).lineSpacing(style.lineSpacing)
    }
}
