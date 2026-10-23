import AppKit
import ShepetalCore
import SwiftUI

/// One row per action: its chord as a key hint and a Change… keycap that records the next chord through the tap.
/// A refused chord shows why. Reset puts the defaults back. Bindings live in UserDefaults ("shortcuts").
final class ShortcutsWindow: NSWindowController, NSWindowDelegate {
    private static let defaultsKey = "shortcuts"
    static var saved: Shortcuts { Shortcuts(stored: UserDefaults.standard.dictionary(forKey: defaultsKey)) }

    private let tap: FnTap
    private let model = ShortcutsModel()
    private var recording: ShortcutAction?

    init(tap: FnTap) {
        self.tap = tap
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Shortcuts"
        window.isReleasedWhenClosed = false
        SmallWindow.style(window)
        super.init(window: window)
        window.delegate = self
        model.change = { [weak self] in self?.change($0) }
        model.reset = { [weak self] in self?.resetDefaults() }
        window.contentView = NSHostingView(rootView: ShortcutsView(model: model))
        let refused = tap.router.shortcuts.refused
        if !refused.isEmpty {
            model.status = "Saved keys for \(refused.map(\.title).joined(separator: ", ")) were not allowed, so the default is back."
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The chord the tap recorded for the row that asked.
    func recorded(_ raw: Set<Int>) {
        guard let action = recording else { return }
        recording = nil
        if let problem = tap.updateRouter({ $0.shortcuts.set(raw, for: action) }) {
            model.status = "\(Key.label(raw)): \(problem.message)"
        } else {
            model.status = ""
            save()
        }
        refresh()
    }

    func windowWillClose(_ notification: Notification) { stopRecording() }

    /// Leaving the window (⌘Tab included) ends the recording, so its keys reach the next app again.
    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    private func stopRecording() {
        guard recording != nil else { return }
        recording = nil
        tap.updateRouter { $0.stopRecording() }
        refresh()
    }

    private func change(_ action: ShortcutAction) {
        recording = action
        model.status = ""
        tap.updateRouter { $0.record() }
        refresh()
    }

    private func resetDefaults() {
        recording = nil
        tap.updateRouter { $0.stopRecording(); $0.shortcuts.reset() }
        model.status = ""
        save()
        refresh()
    }

    private func save() { UserDefaults.standard.set(tap.router.shortcuts.stored, forKey: Self.defaultsKey) }

    private func refresh() {
        model.rows = ShortcutAction.allCases.map { action in
            let isRecording = recording == action
            let chord = tap.router.shortcuts.chord(action)
            return ShortcutsModel.Row(action: action, chord: isRecording || chord.isEmpty ? nil : Key.label(chord),
                                      placeholder: isRecording ? "Press the keys…" : "Not set",
                                      recording: isRecording, enabled: recording == nil || isRecording)
        }
        if !tap.isRunning {
            model.note = "Shortcuts need Input Monitoring. Open Settings > Permissions… in the shepetal window."
        } else if !tap.canSwallow {
            model.note = "Without Accessibility, Esc and the keys of a shortcut also reach the app you are typing in."
        } else {
            let cancel = Key.label(tap.router.shortcuts.chord(.dismiss))
            model.note = "\(cancel) cancels only while shepetal is listening or transcribing. Otherwise it reaches your app."
        }
    }
}

/// What the window shows; ShortcutsWindow fills it and does what its buttons ask.
@MainActor
final class ShortcutsModel: ObservableObject {
    struct Row: Identifiable {
        let action: ShortcutAction
        /// The chord as printed on the keys ("⌃ ⌘ V"), or nil while recording or unset.
        let chord: String?
        let placeholder: String
        let recording: Bool
        let enabled: Bool
        var id: ShortcutAction { action }
    }

    @Published var rows: [Row] = []
    /// Why a chord was refused, or "".
    @Published var status = ""
    @Published var note = ""
    var change: (ShortcutAction) -> Void = { _ in }
    var reset: () -> Void = {}
}

/// Rows on sh-bg: the action, its keys as one key hint, Change… as a small keycap. A refusal is an error line in
/// sh-danger with the alert icon; the note under the rows is app-small in sh-text-muted.
private struct ShortcutsView: View {
    @ObservedObject var model: ShortcutsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SmallWindowTitle("Shortcuts")
            VStack(alignment: .leading, spacing: SH.space4) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row($0) }
                }
                .shHairline(.top)
                if !model.status.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        SHIcon(.circleAlert).padding(.top, 2)
                        Text(model.status).shText(SH.appSmall).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(SH.danger)
                    .accessibilityElement(children: .combine)
                }
                Text(model.note).shText(SH.appSmall).foregroundStyle(SH.textMuted).fixedSize(horizontal: false, vertical: true)
                Button("Reset to defaults", action: model.reset).buttonStyle(.keycap(.secondary))
            }
            .padding([.horizontal, .bottom], SH.space5)
        }
        .frame(width: 520)
        .background(SH.bg)
        .ignoresSafeArea(.container, edges: .top)  // the title sits in the title bar, beside the traffic lights
    }

    private func row(_ r: ShortcutsModel.Row) -> some View {
        HStack(spacing: SH.space4) {
            Text(r.action.title).shText(SH.appStrong).foregroundStyle(SH.text)
            Spacer(minLength: SH.space2)
            if let chord = r.chord {
                SHKbd(chord)
            } else {
                Text(r.placeholder).shText(SH.appSmall).foregroundStyle(SH.textMuted)
            }
            Button("Change…") { model.change(r.action) }
                .buttonStyle(.keycap(.secondary, .sm))
                .disabled(!r.enabled)
                .accessibilityLabel("Change \(r.action.title)")
        }
        .padding(.vertical, 10)
        .frame(minHeight: SH.controlLg)
        .shHairline(.bottom)
        .accessibilityElement(children: .contain)
    }
}
