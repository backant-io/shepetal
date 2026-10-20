import AppKit
import ShepetalCore

/// The frontmost app at dictation start, and for browsers the page URL of its focused window.
/// It goes into the history row only; nothing leaves the Mac.
struct AppContext: Equatable {
    var name = ""
    var bundleId = ""
    var url = ""

    static func capture() -> AppContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return AppContext() }
        let bundleId = app.bundleIdentifier ?? ""
        return AppContext(name: app.localizedName ?? "", bundleId: bundleId,
                          url: Browser.contains(bundleId) ? pageURL(pid: app.processIdentifier) : "")
    }

    /// Breadth-first from the focused window to the first AXWebArea, then its AXURL. Needs Accessibility.
    /// ponytail: a page whose browser exposes no AXWebArea (Chrome before its accessibility tree is
    /// built) gives no URL; set AXEnhancedUserInterface first if that turns out to be common.
    private static func pageURL(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)  // a hung browser must not hold up dictation start
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return "" }
        var queue = [window as! AXUIElement]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while !queue.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            let el = queue.removeFirst()
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" {
                var url: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &url)
                return (url as? URL)?.absoluteString ?? ""
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            queue += children as? [AXUIElement] ?? []
        }
        return ""
    }
}
