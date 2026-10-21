import AppKit
import ShepetalCore

/// F102: the 🤫 menu's per-app off switch. Opening a menu-bar menu leaves the front app in front, so the menu
/// offers the app the user was just in.
@MainActor
final class DictationOff: NSObject {
    let list: AppBlockList
    /// The front app's bundle id and its name as the Dock shows it; a seam for tests.
    let front: @MainActor () -> (bundleId: String, label: String)

    init(list: AppBlockList = AppBlockList(), front: @escaping @MainActor () -> (bundleId: String, label: String) = DictationOff.frontmost) {
        self.list = list
        self.front = front
    }

    static func frontmost() -> (bundleId: String, label: String) {
        let app = NSWorkspace.shared.frontmostApplication
        let id = app?.bundleIdentifier ?? ""
        return (id, app?.localizedName ?? id)
    }

    /// The hint to show instead of dictating, or nil (`AppBlockList.hint`).
    func hint(for input: KeyInput, idle: Bool) -> String? {
        let app = front()
        return list.hint(for: input, idle: idle, bundleId: app.bundleId, name: app.label)
    }

    /// "Turn off/on dictation in <front app>", then the apps turned off, each click turning it back on.
    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let app = front()
        if !app.bundleId.isEmpty, app.bundleId != Bundle.main.bundleIdentifier {  // not shepetal's own windows
            let off = list.blocks(bundleId: app.bundleId)
            let i = NSMenuItem(title: "Turn \(off ? "on" : "off") dictation in \(app.label)", action: #selector(toggle(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = [app.bundleId, app.label]
            items.append(i)
        }
        let apps = list.apps.sorted { ($0.value.lowercased(), $0.key) < ($1.value.lowercased(), $1.key) }
        guard !apps.isEmpty else { return items }
        let menu = NSMenu()
        menu.autoenablesItems = false  // every item is enabled (#207)
        for (id, name) in apps {
            let i = NSMenuItem(title: name, action: #selector(turnOn(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = id
            menu.addItem(i)
        }
        let sub = NSMenuItem(title: "Dictation is off in (click to turn back on)", action: nil, keyEquivalent: "")
        sub.submenu = menu
        items.append(sub)
        return items
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? [String], app.count == 2 else { return }
        list.set(app[0], name: app[1], off: !list.blocks(bundleId: app[0]))
    }

    @objc private func turnOn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        list.set(id, name: "", off: false)
    }
}
