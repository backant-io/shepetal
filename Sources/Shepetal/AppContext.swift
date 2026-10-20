import AppKit
import ShepetalCore

/// The frontmost app at dictation start, and for browsers the page URL of its focused window.
/// It goes into the history row only; nothing leaves the Mac.
struct AppContext: Equatable {
    var name = ""
    var bundleId = ""
    var url = ""

    static func capture() -> Task<AppContext, Never> {
        guard let app = NSWorkspace.shared.frontmostApplication else { return Task { AppContext() } }
        return resolve(AppContext(name: app.localizedName ?? "", bundleId: app.bundleIdentifier ?? ""),
                       pid: app.processIdentifier)
    }

    /// Returns at once. A browser's page URL is looked up on a background thread: the AX walk waits on the
    /// browser, and fn events are timed on the main thread, so a slow page must not hold that thread.
    static func resolve(_ app: AppContext, pid: pid_t,
                        pageURL: @escaping @Sendable (pid_t) -> String = { pageURL(pid: $0) }) -> Task<AppContext, Never> {
        guard Browser.contains(app.bundleId) else { return Task { app } }
        return Task.detached {
            var app = app
            app.url = Browser.historyURL(pageURL(pid))
            return app
        }
    }

    /// Breadth-first from the focused window to the first AXWebArea, then its AXURL. Needs Accessibility.
    /// ponytail: a page whose browser exposes no AXWebArea (Chrome before its accessibility tree is
    /// built) gives no URL; set AXEnhancedUserInterface first if that turns out to be common.
    static func pageURL(pid: pid_t) -> String {
        guard let window = value(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return "" }
        var queue = [window as! AXUIElement]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while !queue.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            let el = queue.removeFirst()
            if value(el, kAXRoleAttribute) as? String == "AXWebArea" {
                return (value(el, kAXURLAttribute) as? URL)?.absoluteString ?? ""
            }
            queue += value(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return ""
    }

    /// A messaging timeout applies only to the element it is set on, so every element gets its own.
    static func value(_ el: AXUIElement, _ attribute: String, timeout: Float = 0.1) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(el, timeout)
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attribute as CFString, &v) == .success ? v : nil
    }
}
