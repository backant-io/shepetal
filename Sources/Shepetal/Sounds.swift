import AppKit
import ShepetalCore

/// Plays the `Chime`s that `ChimeCue` picks, unless "Sounds" is off in the 🤫 menu (on by default).
@MainActor
final class Sounds: NSObject {
    private let sounds = Dictionary(uniqueKeysWithValues: Chime.allCases.map { ($0, NSSound(data: AudioStore.wav($0.samples))) })
    private var cue = ChimeCue()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds") }
    }

    func play(_ action: GestureAction) { play(cue.sound(for: action)) }

    /// `holdThreshold` after `.start`: the start sound, if fn is still held.
    func holdCheck(_ gesture: FnGesture) { play(cue.holdCheck(gesture, at: ProcessInfo.processInfo.systemUptime)) }

    private func play(_ chime: Chime?) {
        guard enabled, let chime, let sound = sounds[chime] ?? nil else { return }
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
