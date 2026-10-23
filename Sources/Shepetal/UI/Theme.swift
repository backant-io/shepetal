// shepetal UI (design/ui): the token types behind Tokens.swift. Colors are read only through the semantic tokens
// (SH.bg, SH.text, SH.signal...), each with its Concrete (light) and Night (dark) value; the theme follows the
// OS appearance through SwiftUI's colorScheme, so a view never picks a theme by hand.
import AppKit
import SwiftUI

/// The namespace of every token: `SH.bg`, `SH.space5`, `SH.durPress`, `SH.appBody`. Values are in Tokens.swift.
enum SH {}

// MARK: color

/// A semantic color with its Concrete and Night value, as `0xRRGGBBAA`. A ShapeStyle, so `.foregroundStyle(SH.text)`
/// and `.background(SH.bg)` follow the environment's colorScheme; `SH.text(scheme)` gives the plain Color where an
/// API wants one (shadows, strokes drawn by hand).
struct SHColor: ShapeStyle, Sendable {
    let name: String
    let light: UInt32
    let dark: UInt32

    init(_ name: String, light: UInt32, dark: UInt32) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    func resolve(in environment: EnvironmentValues) -> Color { self(environment.colorScheme) }

    func callAsFunction(_ scheme: ColorScheme) -> Color { Color.sh(scheme == .dark ? dark : light) }

    /// For AppKit: resolves against the appearance it is drawn in.
    var nsColor: NSColor {
        let light = light, dark = dark
        return NSColor(name: NSColor.Name(name)) { appearance in
            NSColor.sh(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }
}

extension Color {
    /// `0xRRGGBBAA` in sRGB.
    static func sh(_ rgba: UInt32) -> Color {
        Color(.sRGB, red: Double(rgba >> 24 & 0xFF) / 255, green: Double(rgba >> 16 & 0xFF) / 255,
              blue: Double(rgba >> 8 & 0xFF) / 255, opacity: Double(rgba & 0xFF) / 255)
    }
}

extension NSColor {
    static func sh(_ rgba: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}

// MARK: shadow

/// One layer of a CSS box-shadow from tokens.json, in points.
struct SHShadowLayer: Equatable, Sendable {
    let inset: Bool
    let x: CGFloat
    let y: CGFloat
    let blur: CGFloat
    let spread: CGFloat
    let rgba: UInt32

    var color: Color { .sh(rgba) }
}

/// A key's travel shadow or sh-pop, per theme.
struct SHShadow: Sendable {
    let name: String
    let light: [SHShadowLayer]
    let dark: [SHShadowLayer]

    init(_ name: String, light: [SHShadowLayer], dark: [SHShadowLayer]) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    func callAsFunction(_ scheme: ColorScheme) -> [SHShadowLayer] { scheme == .dark ? dark : light }
}

extension View {
    /// Draws CSS box-shadow layers around a shape of `radius`: an inset layer as an inner edge (the keycap's top
    /// highlight or a key hint's side), a solid layer with no blur as the side under the cap, a blurred one as the
    /// cast shadow (negative spread shrinks the shape that casts it), a spread-only one as a ring.
    func shShadow(_ layers: [SHShadowLayer], radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background {
                ZStack {
                    ForEach(layers.indices.reversed(), id: \.self) { i in
                        let l = layers[i]
                        if !l.inset {
                            if l.blur > 0 {
                                // Opaque, so the shadow keeps its alpha; the cap above hides the shape itself.
                                shape.fill(Color.sh(l.rgba | 0xFF))
                                    .padding(-l.spread)
                                    .shadow(color: l.color, radius: l.blur / 2, x: l.x, y: l.y)
                            } else if l.x == 0, l.y == 0 {
                                RoundedRectangle(cornerRadius: radius + l.spread, style: .continuous)
                                    .strokeBorder(l.color, lineWidth: l.spread)
                                    .padding(-l.spread)
                            } else {
                                shape.fill(l.color).padding(-l.spread).offset(x: l.x, y: l.y)
                            }
                        }
                    }
                }
            }
            .overlay {
                ZStack {
                    ForEach(layers.indices, id: \.self) { i in
                        let l = layers[i]
                        if l.inset {
                            // inset 0 Npx 0 c: an N pt band along the top (N > 0) or bottom (N < 0) edge, inside the shape.
                            Rectangle().fill(l.color)
                                .frame(height: abs(l.y))
                                .frame(maxHeight: .infinity, alignment: l.y > 0 ? .top : .bottom)
                        }
                    }
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
    }
}

// MARK: motion

/// A CSS cubic-bezier.
struct SHEasing: Equatable, Sendable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    func animation(_ duration: Double) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }
}

extension SH {
    /// The token animation, or none under Reduce motion (every duration is 0 ms there).
    static func motion(_ easing: SHEasing, _ duration: Double, reduce: Bool) -> Animation? {
        reduce ? nil : easing.animation(duration)
    }

    /// A key going down: sh-dur-press on sh-ease-press.
    static func press(reduce: Bool) -> Animation? { motion(easePress, durPress, reduce: reduce) }
    /// A key coming back up, hover and focus: sh-dur-fast on sh-ease-settle.
    static func settle(reduce: Bool) -> Animation? { motion(easeSettle, durFast, reduce: reduce) }
}

// MARK: focus

extension View {
    /// The one focus ring: 2 pt solid sh-focus, 2 pt outside a shape of `radius`. Replaces the system ring.
    func shFocusRing(_ visible: Bool, radius: CGFloat = SH.radiusSm) -> some View {
        focusEffectDisabled()
            .overlay {
                if visible {
                    RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                        .strokeBorder(SH.focus, lineWidth: 2)
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: hairline

extension View {
    /// A 1 pt sh-border hairline on one edge (rows, the sidebar's right edge).
    func shHairline(_ edge: Edge, _ color: SHColor = SH.border) -> some View {
        overlay(alignment: Alignment(horizontal: edge == .leading ? .leading : edge == .trailing ? .trailing : .center,
                                     vertical: edge == .top ? .top : edge == .bottom ? .bottom : .center)) {
            Rectangle().fill(color)
                .frame(width: edge == .leading || edge == .trailing ? 1 : nil,
                       height: edge == .top || edge == .bottom ? 1 : nil)
                .allowsHitTesting(false)
        }
    }
}
