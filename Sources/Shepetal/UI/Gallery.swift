// The shepetal UI Gallery: every token group and component, in Concrete and Night side by side. Not reachable from
// the app yet; ScreenshotTests draws it (06-gallery) so a change to the foundation shows in the screens artifact.
import AppKit
import SwiftUI

struct SHGallery: View {
    /// The themes to show, side by side.
    var schemes: [ColorScheme] = [.light, .dark]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(schemes, id: \.self) { scheme in
                SHGalleryPane(themeName: scheme == .dark ? "Night" : "Concrete")
                    .environment(\.colorScheme, scheme)
            }
        }
        .onAppear { SHFonts.register() }
    }

    /// An offscreen window holding the Gallery (ScreenshotTests); never ordered front.
    @MainActor
    static func window(schemes: [ColorScheme] = [.light, .dark]) -> NSWindow {
        SHFonts.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760 * CGFloat(schemes.count), height: 1400),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.title = "Gallery"
        window.contentView = NSHostingView(rootView: SHGallery(schemes: schemes))
        return window
    }
}

private struct SHGalleryPane: View {
    let themeName: String
    @State private var on = true
    @State private var off = false
    @State private var appearance = "System"
    @State private var word = "Saoirse"
    @State private var email = "maya@example"
    @State private var screen = "History"

    var body: some View {
        VStack(alignment: .leading, spacing: SH.space6) {
            HStack(alignment: .firstTextBaseline) {
                Text("shepetal").shText(SH.wordmark).foregroundStyle(SH.text)
                Spacer()
                Text(themeName).shText(SH.label).foregroundStyle(SH.textMuted)
            }
            group("Type") { type }
            group("Color") { colors }
            group("Keycaps") { keycaps }
            group("Keys") { keys }
            group("Controls") { controls }
            group("Fields") { fields }
            group("Rows") { rows }
            group("Sidebar and menu") { navigation }
            group("Notices") { notices }
            group("Indicator") { indicator }
        }
        .padding(SH.space5)
        .padding(.top, 28)  // under the title bar
        .frame(width: 760, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SH.bg)
    }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: SH.space3) {
            Text(title).shText(SH.appHeading).foregroundStyle(SH.text)
            content()
        }
    }

    private var type: some View {
        VStack(alignment: .leading, spacing: SH.space2) {
            Text("History").shText(SH.appTitle)
            Text("Shortcut").shText(SH.appHeading)
            Text("Accessibility lets shepetal paste your text where your cursor is.").shText(SH.appBody)
            Text("Record").shText(SH.appStrong)
            Text("Double-tap fn for hands-free.").shText(SH.appSmall).foregroundStyle(SH.textMuted)
            Text("Chat  ·  10:42  ·  38 words").shText(SH.label).foregroundStyle(SH.textMuted)
            Text("~/shepetal/recordings").shText(SH.code)
            Text("Plans for the spring garden").shText(SH.spoken.with(size: 28))
        }
        .foregroundStyle(SH.text)
    }

    private var colors: some View {
        let semantic: [SHColor] = [SH.bg, SH.bgRaised, SH.bgSunken, SH.bgField, SH.text, SH.textMuted, SH.border,
                                   SH.borderStrong, SH.primaryFill, SH.keyFill, SH.accent, SH.focus, SH.signal, SH.danger]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SH.space2), count: 7), spacing: SH.space2) {
            ForEach(semantic, id: \.name) { c in
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous).fill(c).frame(height: 28)
                        .overlay(RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous).strokeBorder(SH.border, lineWidth: 1))
                    Text(c.name.replacingOccurrences(of: "sh-", with: "")).shText(SH.caption).foregroundStyle(SH.textMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    private var keycaps: some View {
        VStack(alignment: .leading, spacing: SH.space3) {
            HStack(spacing: SH.space3) {
                Button("Continue") {}.buttonStyle(.keycap(.primary))
                Button("Not now") {}.buttonStyle(.keycap())
                Button { } label: { Label { Text("Copy text") } icon: { SHIcon(.copy) } }.buttonStyle(.keycap(.quiet))
                Button("Delete recording") {}.buttonStyle(.keycap(.danger))
                Button("Record") {}.buttonStyle(.keycap(.signal))
            }
            HStack(alignment: .bottom, spacing: SH.space3) {
                ForEach(SHKeycapStyle.Size.allCases, id: \.self) { size in
                    Button(size == .sm ? "Small" : size == .md ? "Default" : "Large") {}.buttonStyle(.keycap(.secondary, size))
                }
                Button("Unavailable") {}.buttonStyle(.keycap(.primary)).disabled(true)
                Button { } label: { SHIcon(.settings) }.buttonStyle(.keycap(.quiet, .sm)).accessibilityLabel("Settings")
            }
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: SH.space2) {
            HStack(spacing: 6) {
                Text("Double-tap").shText(SH.appBody)
                SHKbd("fn", signal: true)
                Text("for hands-free. Paste with").shText(SH.appBody)
                SHKbd(["⌘", "V"])
            }
            HStack(spacing: 6) {
                Text("On Windows and Linux:").shText(SH.appBody)
                SHKbd(["Ctrl", "V"], os: .windows)
            }
        }
        .foregroundStyle(SH.text)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: SH.space3) {
            Toggle("Start at login", isOn: $on).toggleStyle(.shSwitch)
            Toggle("Record meetings when I say yes", isOn: $off).toggleStyle(.shSwitch)
            SHSegmented("Appearance", selection: $appearance,
                        options: [("System", "System"), ("Concrete", "Concrete"), ("Night", "Night")])
        }
    }

    private var fields: some View {
        HStack(alignment: .top, spacing: SH.space5) {
            SHField("Word", help: "Spelled the way you want it typed.") {
                TextField("e.g. Saoirse", text: $word).textFieldStyle(.shField)
            }
            SHField("Email", error: "Add the part after the @, like example.com.") {
                TextField("you@example.com", text: $email).textFieldStyle(.shField(invalid: true))
            }
        }
    }

    private var rows: some View {
        SHRows {
            SHRow("Shortcut", title: "fn", help: "Double-tap fn for hands-free.") {
                Button("Change") {}.buttonStyle(.keycap(.secondary, .sm))
            }
            SHRow("Network", title: "Offline")
            SHRow("Login", title: "Start at login") { Toggle("Start at login", isOn: $on).toggleStyle(.shSwitch).labelsHidden() }
        }
    }

    private var navigation: some View {
        HStack(alignment: .top, spacing: SH.space5) {
            SHSidebar {
                ForEach(Self.screens.indices, id: \.self) { i in
                    let name = Self.screens[i].0
                    SHSidebarItem(name, icon: Self.screens[i].1, current: name == screen) { screen = name }
                }
            }
            .frame(height: 200)
            SHMenu {
                SHMenuHead {
                    HStack(spacing: 8) {
                        SHIndicator(.handsFree)
                        Text("Hands-free").shText(SH.label).foregroundStyle(SH.text)
                    }
                }
                SHMenuSeparator()
                SHMenuRow("Home") {}
                SHMenuRow("History") {}
                SHMenuRow("Meetings") {}
                SHMenuRow("Settings", hint: "⌘,") {}
                SHMenuSeparator()
                SHMenuRow("Quit shepetal", hint: "⌘Q") {}
            }
            .frame(width: 240)
        }
    }

    private static let screens: [(String, SHIconName)] = [("Home", .house), ("History", .rotateCcwClock),
                                                           ("Meetings", .users), ("Settings", .settings),
                                                           ("Dictionary", .bookA)]

    private var notices: some View {
        VStack(alignment: .leading, spacing: SH.space3) {
            SHNotice("Password fields block pasting.", message: "Your text is on the clipboard: press ⌘V.")
            SHNotice("The mic is unavailable.", message: "Your recording is saved. Re-transcribe it from History when the mic is back.",
                     danger: true) {
                Button("Open Sound settings") {}.buttonStyle(.keycap(.secondary, .sm))
            }
        }
    }

    private var indicator: some View {
        VStack(alignment: .leading, spacing: SH.space4) {
            HStack(spacing: SH.space6) {
                ForEach([SHIndicator.State.recording, .handsFree, .writing], id: \.name) { state in
                    HStack(spacing: 6) {
                        SHIndicator(state, size: .large)
                        Text(state.name).shText(SH.label).foregroundStyle(SH.text)
                    }
                }
                SHIndicator(.note("Mic is off. Text saved."), size: .large)
            }
            HStack(spacing: SH.space5) {
                SHIndicator(.recording)
                SHIndicator(.handsFree)
                SHIndicator(.writing)
                Text("18 pt, as on screen").shText(SH.label).foregroundStyle(SH.textMuted)
            }
        }
    }
}
