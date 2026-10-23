// Row, Sidebar, Notice and Menu (design/ui/components). Cards and panels are flat (a ground change and a hairline);
// only floating things (menus, popovers, the reminder) carry sh-pop.
import SwiftUI

// MARK: Row

/// The spec row: a 104 pt mono label column, the title and help, one control on the right, a hairline below.
/// Put rows in `SHRows` for the hairline above the first.
struct SHRow<Action: View>: View {
    let label: String
    let title: String
    var help: String?
    @ViewBuilder let action: Action

    init(_ label: String, title: String, help: String? = nil, @ViewBuilder action: () -> Action) {
        self.label = label
        self.title = title
        self.help = help
        self.action = action()
    }

    var body: some View {
        // The label and the title share a baseline; the control sits centred on the row.
        HStack(alignment: .center, spacing: SH.space5) {
            HStack(alignment: .firstTextBaseline, spacing: SH.space5) {
                Text(label).shText(SH.label).foregroundStyle(SH.textMuted)
                    .frame(width: SH.rowLabel, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).shText(SH.appStrong).foregroundStyle(SH.text)
                    if let help { Text(help).shText(SH.appSmall).foregroundStyle(SH.textMuted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            action
        }
        .padding(.vertical, 14)
        .shHairline(.bottom)
        .accessibilityElement(children: .contain)
    }
}

extension SHRow where Action == EmptyView {
    init(_ label: String, title: String, help: String? = nil) {
        self.init(label, title: title, help: help) { EmptyView() }
    }
}

struct SHRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.shHairline(.top)
    }
}

// MARK: Sidebar

/// The app's navigation on the sunken ground, 200 pt wide, with a hairline on its right edge.
struct SHSidebar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(width: SH.sidebar, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(SH.bgSunken)
            .shHairline(.trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("shepetal")
    }
}

/// One screen in the sidebar: a 16 pt icon and its name; the current one is a raised cap.
struct SHSidebarItem: View {
    let icon: SHIconName
    let title: String
    let current: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hover = false

    init(_ title: String, icon: SHIconName, current: Bool, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.current = current
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SHIcon(icon)
                Text(title).shText(current ? SH.appStrong : SH.appBody)
            }
            .foregroundStyle(current || hover ? SH.text : SH.textMuted)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: SH.controlSm, alignment: .leading)
            .background { ground }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .shFocusRing(focused)
        .onHover { inside in withAnimation(SH.settle(reduce: reduceMotion)) { hover = inside } }
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    @ViewBuilder private var ground: some View {
        let shape = RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous)
        if current {
            shape.fill(SH.bgRaised)
                .shShadow([SHShadowLayer(inset: false, x: 0, y: 1, blur: 0, spread: 0,
                                         rgba: scheme == .dark ? SH.keySide.dark : SH.keySide.light),
                           SHShadowLayer(inset: false, x: 0, y: 0, blur: 0, spread: 1,
                                         rgba: scheme == .dark ? SH.border.dark : SH.border.light)], radius: SH.radiusSm)
        } else if hover {
            shape.fill(SH.text(scheme).opacity(0.06))
        }
    }
}

// MARK: Notice

/// An inline message: what happened in one line, the next step, and the action that fixes it. `danger` only when
/// something failed and needs action now.
struct SHNotice<Actions: View>: View {
    let title: String
    let message: String
    var danger = false
    @ViewBuilder let actions: Actions

    init(_ title: String, message: String, danger: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.danger = danger
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SHIcon(danger ? .triangleAlert : .info)
                .foregroundStyle(danger ? SH.danger : SH.textMuted)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).shText(SH.appStrong).foregroundStyle(danger ? SH.danger : SH.text)
                Text(message).shText(SH.appSmall).foregroundStyle(SH.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if Actions.self != EmptyView.self { HStack(spacing: SH.space2) { actions }.padding(.top, 6) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(SH.bgRaised, in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous).strokeBorder(SH.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(danger ? "Error: \(title)" : title)
    }
}

extension SHNotice where Actions == EmptyView {
    init(_ title: String, message: String, danger: Bool = false) {
        self.init(title, message: message, danger: danger) { EmptyView() }
    }
}

// MARK: Menu

/// A raised panel of rows on sh-pop: the 🤫 menu and context menus.
struct SHMenu<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(4)
            .frame(minWidth: 220, alignment: .leading)
            .background(SH.bgRaised, in: RoundedRectangle(cornerRadius: SH.radiusMd, style: .continuous))
            .shShadow(SH.pop(scheme), radius: SH.radiusMd)
            .accessibilityElement(children: .contain)
    }
}

/// One menu row: the hovered or focused row is ink (sh-primary-fill), its hint follows.
struct SHMenuRow: View {
    let title: String
    var hint: String?
    let action: () -> Void

    @FocusState private var focused: Bool
    @State private var hover = false

    init(_ title: String, hint: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.action = action
    }

    var body: some View {
        let lit = hover || focused
        Button(action: action) {
            HStack(spacing: SH.space5) {
                Text(title).shText(SH.appBody)
                Spacer(minLength: 0)
                if let hint { Text(hint).font(SHFonts.font(.mono, size: 12)).foregroundStyle(lit ? SH.onPrimary : SH.textMuted) }
            }
            .foregroundStyle(lit ? SH.onPrimary : SH.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: SH.controlSm)
            .background(lit ? AnyShapeStyle(SH.primaryFill) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .shFocusRing(focused)
        .onHover { hover = $0 }
    }
}

/// A hairline between groups of menu rows.
struct SHMenuSeparator: View {
    var body: some View {
        Rectangle().fill(SH.border).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}

/// The state in words at the top of the 🤫 menu.
struct SHMenuHead<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.padding(.top, 6).padding(.bottom, 4).padding(.horizontal, 10)
    }
}
