// Settings groups (design/ui/components/SettingsScreen): an app-heading over a run of rows, and a row whose main
// column holds a view (a field, a chart, two values side by side) instead of a title and help. Added for the
// Settings and Home sections; Row's own SHRow and SHRows are unchanged.
import SwiftUI

/// A heading, its rows with the hairline above the first, and optional help under them in app-small.
/// `SHRowGroup("Email") { SHRow(...) } footer: { Text("...") }`
struct SHRowGroup<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.space2) {
            Text(title).shText(SH.appHeading).foregroundStyle(SH.text)
                .accessibilityAddTraits(.isHeader)
            SHRows { content }
            if Footer.self != EmptyView.self {
                VStack(alignment: .leading, spacing: SH.space2) { footer }
                    .shText(SH.appSmall)
                    .foregroundStyle(SH.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension SHRowGroup where Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

/// The spec row with a view in its main column: the 104 pt mono label, the view, one control on the right, a
/// hairline below. The label sits on the main view's first baseline; a view without text sets that guide itself.
struct SHContentRow<Main: View, Action: View>: View {
    let label: String
    @ViewBuilder let main: Main
    @ViewBuilder let action: Action

    init(_ label: String, @ViewBuilder main: () -> Main, @ViewBuilder action: () -> Action) {
        self.label = label
        self.main = main()
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .center, spacing: SH.space5) {
            HStack(alignment: .firstTextBaseline, spacing: SH.space5) {
                Text(label).shText(SH.label).foregroundStyle(SH.textMuted)
                    .frame(width: SH.rowLabel, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                main.frame(maxWidth: .infinity, alignment: .leading)
            }
            action
        }
        .padding(.vertical, 14)
        .shHairline(.bottom)
        .accessibilityElement(children: .contain)
    }
}

extension SHContentRow where Action == EmptyView {
    init(_ label: String, @ViewBuilder main: () -> Main) {
        self.init(label, main: main) { EmptyView() }
    }
}

/// An error line under a control: the alert icon and one line in sh-danger that says what happened.
struct SHErrorLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            SHIcon(.circleAlert).padding(.top, 1)
            Text(text).shText(SH.appSmall).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .foregroundStyle(SH.danger)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(text)")
    }
}
