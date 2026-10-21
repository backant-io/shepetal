import AppKit
import ShepetalCore

/// F28: remembers the http(s) links the user copies, for "insert link". Polls the change count once a second and
/// reads only a new item: never one with the Concealed or Transient marker (password managers, Shepetal's own
/// pastes, whose promised data must not be pulled by anyone but the target app), and on macOS 15.4+ only one the
/// system already detects as a web URL, so other copies are never read. Nothing is written to disk.
@MainActor
final class LinkWatcher {
    let pasteboard: NSPasteboard
    private(set) var memory = LinkMemory()
    private var seen: Int
    private var timer: Timer?

    /// What is on the pasteboard now counts as seen: only later copies are remembered.
    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        seen = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; Task { await self.check() } }
        }
    }

    func links(now: Date = Date()) -> [String] { memory.links(now: now) }

    /// One poll. ponytail: the Inserter's restore of the user's clipboard counts as a new copy, so a link that
    /// was on the clipboard before a paste starts its 24 hours again.
    func check(now: Date = Date()) async {
        let count = pasteboard.changeCount
        guard count != seen else { return }
        seen = count
        guard !Links.skips(types: (pasteboard.types ?? []).map(\.rawValue)) else { return }
        if #available(macOS 15.4, *) {
            guard Self.mayRead(pasteboard.accessBehavior), await probableWebURL(), pasteboard.changeCount == count else { return }
        }
        guard let url = pasteboard.string(forType: .string).flatMap(Links.url(from:)) else { return }
        memory.add(url, at: now)
    }

    /// Not when the user set shepetal to Ask or Deny in System Settings: a read would ask on every copy.
    @available(macOS 15.4, *)
    static func mayRead(_ behavior: NSPasteboard.AccessBehavior) -> Bool {
        behavior == .default || behavior == .alwaysAllow
    }

    /// The system's own check, which reads nothing and asks nothing (NSPasteboard.h). The answer comes on another
    /// thread, so the handler is @Sendable, not main-actor.
    @available(macOS 15.4, *)
    private func probableWebURL() async -> Bool {
        await withCheckedContinuation { done in
            pasteboard.__detectPatterns(forPatterns: [__NSPasteboardDetectionPattern.__probableWebURL]) { @Sendable found, _ in
                done.resume(returning: found?.contains(__NSPasteboardDetectionPattern.__probableWebURL) ?? false)
            }
        }
    }
}
