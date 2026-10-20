import AppKit
import ShepetalCore

/// Remembers the frontmost app and its focused element when dictation starts, and puts focus back
/// there before the paste (`FocusPlan`). Needs Accessibility; without it nothing is stored and the
/// paste goes where focus is.
@MainActor
final class FocusRestore {
    private var app: NSRunningApplication?
    private var element: AXUIElement?

    func store() {
        app = NSWorkspace.shared.frontmostApplication
        element = Self.focusedElement()
    }

    func restore() async {
        guard let app else { return }
        let alive = element.map { el in
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) != .invalidUIElement
        } ?? false
        let plan = FocusPlan.decide(appRunning: !app.isTerminated, appIsFront: isFront(app),
                                    elementAlive: alive, elementIsFocused: isFocused())
        guard plan == .activateApp || plan == .activateAndFocus else { return }
        app.activate()
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if plan == .activateAndFocus, let element {
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success {
                AXUIElementPerformAction(window as! AXUIElement, kAXRaiseAction as CFString)
            }
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + FocusPlan.focusWait
        while ProcessInfo.processInfo.systemUptime < deadline, !(isFront(app) && (plan == .activateApp || isFocused())) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isFront(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func isFocused() -> Bool {
        guard let element, let now = Self.focusedElement() else { return false }
        return CFEqual(element, now)
    }

    static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }
}
