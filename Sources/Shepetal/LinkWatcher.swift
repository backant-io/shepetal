import AppKit
import ShepetalCore

/// F28: remembers the http(s) links the user copies, for "insert link". Polls the change count once a second and
/// reads only a new item: never one with the Concealed or Transient marker (password managers, Shepetal's own
/// pastes, whose promised data must not be pulled by anyone but the target app), and on macOS 15.4+ only one the
/// system already detects as a web URL, so other copies are never read. Nothing is written to disk.
///
/// macOS 15.4+ pasteboard privacy: until shepetal has raised a paste alert, the general pasteboard reports
/// `.default`, which Apple documents as "ask upon programmatic access". So once Apple enforces it, the first
/// copied link that is read raises the alert ("shepetal would like to paste"). After that the state is `.ask`,
/// the watcher reads nothing more, and "insert link" stays as words until the user picks Always Allow for
/// shepetal in System Settings. ponytail: no opt-in before that first read; that is Pavel's call (#259).
@MainActor
final class LinkWatcher {
    let pasteboard: NSPasteboard
    private(set) var memory = LinkMemory()
    private var seen: Int
    private var timer: Timer?
    /// macOS 15.4+: false when shepetal is set to Ask or Deny in System Settings. Tests stub it.
    var mayRead: () -> Bool
    /// macOS 15.4+: the system's check that the copy is a web URL, which reads nothing and asks nothing
    /// (NSPasteboard.h). Tests stub it.
    var looksLikeURL: () async -> Bool

    /// What is on the pasteboard now counts as seen: only later copies are remembered.
    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        seen = pasteboard.changeCount
        mayRead = {
            guard #available(macOS 15.4, *) else { return true }
            return LinkWatcher.allows(pasteboard.accessBehavior)
        }
        looksLikeURL = {
            guard #available(macOS 15.4, *) else { return true }
            return await LinkWatcher.probableWebURL(pasteboard)
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; Task { await self.check() } }
        }
    }

    func links(now: Date = Date()) -> [String?] { memory.links(now: now) }

    /// One poll. A copy that changed during the URL check is left for the next poll, so nothing unchecked is
    /// read. ponytail: the Inserter's restore of the user's clipboard counts as a new copy, so a link that was on
    /// the clipboard before a paste starts its 24 hours again.
    func check(now: Date = Date()) async {
        let count = pasteboard.changeCount
        guard count != seen else { return }
        seen = count
        guard !Links.skips(types: (pasteboard.types ?? []).map(\.rawValue)), mayRead(), await looksLikeURL(),
              pasteboard.changeCount == count, let copied = pasteboard.string(forType: .string) else { return }
        memory.add(copied, at: now)
    }

    /// `.default` is read: see the type's comment for the alert it raises once Apple enforces pasteboard privacy.
    @available(macOS 15.4, *)
    static func allows(_ behavior: NSPasteboard.AccessBehavior) -> Bool {
        behavior == .default || behavior == .alwaysAllow
    }

    /// The answer comes on another thread, so the handler is @Sendable, not main-actor.
    @available(macOS 15.4, *)
    static func probableWebURL(_ pasteboard: NSPasteboard) async -> Bool {
        await withCheckedContinuation { done in
            pasteboard.__detectPatterns(forPatterns: [__NSPasteboardDetectionPattern.__probableWebURL]) { @Sendable found, _ in
                done.resume(returning: found?.contains(__NSPasteboardDetectionPattern.__probableWebURL) ?? false)
            }
        }
    }
}
