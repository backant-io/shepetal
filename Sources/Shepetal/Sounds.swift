import AppKit
import ShepetalCore

/// Plays the `Chime` for a gesture, unless "Sounds" is off in the 🤫 menu (on by default).
@MainActor
final class Sounds: NSObject {
    private let sounds = Dictionary(uniqueKeysWithValues: Chime.allCases.map { ($0, NSSound(data: AudioStore.wav($0.samples))) })

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds") }
    }

    func play(_ action: GestureAction) {
        guard enabled, let chime = Chime(action), let sound = sounds[chime] ?? nil else { return }
        sound.stop()
        sound.play()
    }

    var menuItem: NSMenuItem {
        let i = NSMenuItem(title: "Sounds", action: #selector(toggle), keyEquivalent: "")
        i.target = self
        i.state = enabled ? .on : .off
        return i
    }

    @objc private func toggle() { enabled.toggle() }
}
