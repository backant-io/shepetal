// Button (design/ui/components/Button): a keycap with a side, which goes down by its travel when pressed and comes
// back up. No bounce; under Reduce motion it moves at once. One primary keycap per view; signal only while something
// is live; danger is a secondary cap with red text and a verb that names what goes.
import SwiftUI

struct SHKeycapStyle: ButtonStyle {
    enum Variant: CaseIterable, Sendable { case primary, secondary, quiet, danger, signal }
    enum Size: CaseIterable, Sendable { case sm, md, lg }

    var variant: Variant = .secondary
    var size: Size = .md

    func makeBody(configuration: Configuration) -> some View {
        SHKeycap(configuration: configuration, variant: variant, size: size)
    }
}

extension ButtonStyle where Self == SHKeycapStyle {
    /// `.buttonStyle(.keycap(.primary))`
    static func keycap(_ variant: SHKeycapStyle.Variant = .secondary, _ size: SHKeycapStyle.Size = .md) -> SHKeycapStyle {
        SHKeycapStyle(variant: variant, size: size)
    }
}

private struct SHKeycap: View {
    let configuration: ButtonStyleConfiguration
    let variant: SHKeycapStyle.Variant
    let size: SHKeycapStyle.Size

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    private var pressed: Bool { configuration.isPressed && enabled }

    var body: some View {
        configuration.label
            .labelStyle(SHIconLabelStyle())
            .shText(label)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, padding)
            .frame(minHeight: height)
            .background(fill(scheme), in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
            .shShadow(shadow, radius: SH.radiusSm)
            .contentShape(RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
            .offset(y: pressed ? travel : 0)
            .shFocusRing(focused)
            .padding(.bottom, side)  // the room its side needs
            .onHover { inside in withAnimation(SH.settle(reduce: reduceMotion)) { hover = inside } }
            .animation(pressed ? SH.press(reduce: reduceMotion) : SH.settle(reduce: reduceMotion), value: pressed)
    }

    private var label: SHTextStyle {
        let base = SH.appStrong
        switch size {
        case .sm: return base.with(size: 13)
        case .md: return base
        case .lg: return base.with(size: 15)
        }
    }

    private var height: CGFloat {
        switch size {
        case .sm: SH.controlSm
        case .md: SH.controlMd
        case .lg: SH.controlLg
        }
    }

    private var padding: CGFloat {
        switch size {
        case .sm: 12
        case .md: 16
        case .lg: SH.space5
        }
    }

    /// How far the cap goes down, and the side that shows how far it can.
    private var travel: CGFloat { variant == .primary ? SH.travelPrimary : variant == .quiet ? 0 : SH.travel }
    private var side: CGFloat { variant == .primary ? 4 : variant == .quiet ? 0 : 3 }

    private var foreground: SHColor {
        guard enabled else { return SH.textDisabled }
        switch variant {
        case .primary: return SH.onPrimary
        case .secondary, .quiet: return SH.text
        case .danger: return SH.danger
        case .signal: return SH.onSignal
        }
    }

    private func fill(_ scheme: ColorScheme) -> Color {
        switch variant {
        case .primary:
            if !enabled { return SH.bgSunken(scheme) }
            return hover && !pressed ? SH.primaryHover(scheme) : SH.primaryFill(scheme)
        case .secondary, .danger: return SH.keyFill(scheme)
        case .quiet: return hover || pressed ? SH.bgSunken(scheme) : .clear
        case .signal: return pressed ? SH.signal600(scheme) : SH.signal(scheme)
        }
    }

    private var shadow: [SHShadowLayer] {
        switch variant {
        case .primary:
            guard enabled else { return [] }
            let token = pressed ? SH.keyPrimaryDown : SH.keyPrimary
            return token(scheme)
        case .secondary, .danger:
            let token = pressed ? SH.keyDown : SH.key
            return token(scheme)
        case .quiet: return []
        case .signal: return pressed ? Self.signalDown : Self.signalRest
        }
    }

    // The live keycap (bundle.css .sh-btn--signal): its side is sh-signal-700 in both themes.
    private static let signalRest = [
        SHShadowLayer(inset: true, x: 0, y: 1, blur: 0, spread: 0, rgba: 0xFFFFFF40),
        SHShadowLayer(inset: false, x: 0, y: 3, blur: 0, spread: 0, rgba: SH.signal700.light),
        SHShadowLayer(inset: false, x: 0, y: 7, blur: 12, spread: -6, rgba: 0x16151259),
    ]
    private static let signalDown = [
        SHShadowLayer(inset: true, x: 0, y: 1, blur: 0, spread: 0, rgba: 0xFFFFFF33),
        SHShadowLayer(inset: false, x: 0, y: 1, blur: 0, spread: 0, rgba: SH.signal700.light),
    ]
}

/// A 16 pt icon before the label, 8 pt apart (sh-space-2).
struct SHIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.space2) {
            configuration.icon.frame(width: 16, height: 16)
            configuration.title
        }
    }
}
