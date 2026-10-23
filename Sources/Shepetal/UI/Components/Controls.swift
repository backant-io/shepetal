// Toggle, Segmented, TextField and Kbd (design/ui/components). Edges that must be seen are sh-border-strong; the
// toggle's LED is its only signal mark; every control draws the sh-focus ring when it has keyboard focus.
import SwiftUI

// MARK: Toggle

/// A switch drawn as a small keycap that slides across and lights its LED when on.
/// `Toggle("Record meetings when I say yes", isOn: $on).toggleStyle(.shSwitch)`
struct SHToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SHToggle(configuration: configuration)
    }
}

extension ToggleStyle where Self == SHToggleStyle {
    static var shSwitch: SHToggleStyle { SHToggleStyle() }
}

private struct SHToggle: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        let on = configuration.isOn
        Button { configuration.$isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 10) {
                track(on)
                configuration.label.shText(SH.appBody).foregroundStyle(enabled ? SH.text : SH.textDisabled)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }

    private func track(_ on: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous)
                .fill(on ? SH.primaryFill(scheme) : SH.bgSunken(scheme))
                .overlay {
                    if !on {
                        RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous).strokeBorder(SH.borderStrong, lineWidth: 1)
                    }
                }
            // The cap: 18 x 16 with a 2 pt side.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(SH.keyFill)
                .frame(width: 18, height: 16)
                .shShadow([SHShadowLayer(inset: true, x: 0, y: 1, blur: 0, spread: 0, rgba: 0xFFFFFF99),
                           SHShadowLayer(inset: false, x: 0, y: 2, blur: 0, spread: 0,
                                         rgba: scheme == .dark ? SH.keySide.dark : SH.keySide.light)], radius: 3)
                .offset(x: on ? 20 : 2, y: 2)
            // The LED.
            RoundedRectangle(cornerRadius: 1).fill(on ? SH.signal(scheme) : SH.textDisabled(scheme))
                .frame(width: 6, height: 2)
                .offset(x: on ? 26 : 8, y: 9)
        }
        .frame(width: 40, height: 22)
        .opacity(enabled ? 1 : 0.5)
        .shFocusRing(focused)
        .animation(SH.settle(reduce: reduceMotion), value: on)
    }
}

// MARK: Segmented

/// Two to four mutually exclusive options in a sunken well; the chosen one is a raised cap.
struct SHSegmented<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                SHSegment(label: options[i].label, selected: options[i].value == selection) {
                    withAnimation(SH.settle(reduce: reduceMotion)) { selection = options[i].value }
                }
            }
        }
        .padding(2)
        .background(SH.bgSunken, in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous).strokeBorder(SH.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SHSegment: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .shText(selected ? SH.appSmall.with(weight: 560) : SH.appSmall)
                .foregroundStyle(selected || hover ? SH.text : SH.textMuted)
                .padding(.horizontal, 12)
                .frame(minHeight: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(SH.keyFill)
                            .shShadow([SHShadowLayer(inset: false, x: 0, y: 1, blur: 0, spread: 0,
                                                     rgba: scheme == .dark ? SH.keySide.dark : SH.keySide.light),
                                       SHShadowLayer(inset: false, x: 0, y: 0, blur: 0, spread: 1,
                                                     rgba: scheme == .dark ? SH.border.dark : SH.border.light)], radius: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .shFocusRing(focused, radius: 3)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: TextField

/// A text input on the field ground with a sh-border-strong edge (sh-danger when invalid).
/// `TextField("e.g. Saoirse", text: $word).textFieldStyle(.shField)`
struct SHTextFieldStyle: TextFieldStyle {
    var invalid = false

    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        SHFieldBox(invalid: invalid) { configuration }
    }
}

extension TextFieldStyle where Self == SHTextFieldStyle {
    static var shField: SHTextFieldStyle { SHTextFieldStyle() }
    static func shField(invalid: Bool) -> SHTextFieldStyle { SHTextFieldStyle(invalid: invalid) }
}

private struct SHFieldBox<Content: View>: View {
    let invalid: Bool
    @ViewBuilder let content: Content
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        content
            .textFieldStyle(.plain)
            .shText(SH.appBody)
            .foregroundStyle(SH.text)
            .focused($focused)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(minHeight: SH.controlMd)
            .background(SH.bgField, in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous)
                .strokeBorder(invalid ? SH.danger : hover ? SH.textMuted : SH.borderStrong, lineWidth: 1))
            .shFocusRing(focused)
            .onHover { hover = $0 }
    }
}

/// A labelled field: the label, the control, then help, or an error that says what happened and what to do.
struct SHField<Control: View>: View {
    let label: String
    var help: String?
    var error: String?
    @ViewBuilder let control: Control

    init(_ label: String, help: String? = nil, error: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.help = help
        self.error = error
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).shText(SH.appSmall.with(weight: 560)).foregroundStyle(SH.text)
            control
                .accessibilityLabel(label)
                .accessibilityHint(error ?? help ?? "")
            if let error {
                HStack(alignment: .top, spacing: 6) {
                    SHIcon(.circleAlert).padding(.top, 1)
                    Text(error).shText(SH.appSmall)
                }
                .foregroundStyle(SH.danger)
                .accessibilityElement(children: .combine)
            } else if let help {
                Text(help).shText(SH.appSmall).foregroundStyle(SH.textMuted)
            }
        }
    }
}

// MARK: Kbd

/// A key hint: a small keycap in running text or a menu. One cap per key; on the Mac a shortcut is one cap with
/// the symbol and the letter (⌘V, no plus), on Windows and Linux one cap per key joined by a plus.
struct SHKbd: View {
    enum OS: Sendable { case mac, windows, linux }

    let keys: [String]
    var os: OS = .mac
    var signal = false
    var size: CGFloat = 12

    /// `SHKbd("fn", signal: true)`, `SHKbd(["⌘", "V"])` (one cap: ⌘V), `SHKbd(["Ctrl", "V"], os: .windows)`.
    init(_ keys: [String], os: OS = .mac, signal: Bool = false, size: CGFloat = 12) {
        self.keys = keys
        self.os = os
        self.signal = signal
        self.size = size
    }

    init(_ key: String, signal: Bool = false, size: CGFloat = 12) {
        self.init([key], signal: signal, size: size)
    }

    /// The caps as drawn: the Mac joins a shortcut into one.
    var caps: [String] { os == .mac ? [keys.joined()] : keys }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(caps.indices, id: \.self) { i in
                if i > 0 {
                    Text("+").font(SHFonts.font(.mono, size: size)).foregroundStyle(SH.textMuted).padding(.horizontal, size * 0.1)
                }
                cap(caps[i])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caps.joined(separator: " "))
    }

    private func cap(_ legend: String) -> some View {
        Text(legend)
            .font(SHFonts.font(.mono, size: size))
            .tracking(0.01 * size)
            .foregroundStyle(signal ? SH.onSignal : SH.text)
            .padding(.top, size * 0.12)
            .padding(.bottom, size * 0.16)
            .padding(.horizontal, size * 0.42)
            .frame(minWidth: size * 1.6)
            .background(signal ? SH.signal(scheme) : SH.keyFill(scheme),
                        in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
            .shShadow(signal ? [SHShadowLayer(inset: true, x: 0, y: -1, blur: 0, spread: 0, rgba: SH.signal700.light)]
                             : SH.keyHint(scheme) + [SHShadowLayer(inset: false, x: 0, y: 0, blur: 0, spread: 1,
                                                                   rgba: scheme == .dark ? SH.border.dark : SH.border.light)],
                      radius: SH.radiusSm)
    }
}

extension SHFonts {
    /// A face of a family at a size, at the family's text weight (Archivo 480, the others 400 or 500).
    static func font(_ family: SHFontFamily, size: CGFloat, weight: CGFloat? = nil) -> Font {
        Font(ctFont(family, size: size, weight: weight ?? (family == .ui ? 480 : family == .serif ? 500 : 400)))
    }
}
