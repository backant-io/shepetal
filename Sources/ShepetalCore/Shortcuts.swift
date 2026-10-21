import Foundation

/// What a shortcut does (docs/re/dictation-input.md 1 and 2.4). Actions missing from `Shortcuts.defaults`
/// (open notes) have no chord until the user records one.
public enum ShortcutAction: String, CaseIterable {
    case ptt, handsFree, dismiss, pasteLast, copyLast, openNotes
    case polish  // F45: rewrite the selected text with the active saved prompt

    /// Our own wording, for the Shortcuts window.
    public var title: String {
        switch self {
        case .ptt: "Hold to talk"
        case .handsFree: "Hands-free on or off"
        case .dismiss: "Cancel dictation"
        case .pasteLast: "Paste last transcript"
        case .copyLast: "Copy last transcript"
        case .openNotes: "Open notes"
        case .polish: "Polish selected text"
        }
    }
}

/// Why a chord was refused. The messages are ours.
public enum ChordProblem: String, Equatable {
    case tooManyKeys, noModifier, typing, leftRightSame, inUse, blocked

    public var message: String {
        switch self {
        case .tooManyKeys: "Use 3 keys or fewer."
        case .noModifier: "Add fn, ⌃, ⌥, ⇧, ⌘ or a mouse button."
        case .typing: "These keys type text. Add fn, ⌃ or ⌘."
        case .leftRightSame: "Use one side of a modifier, not both."
        case .inUse: "Another action already uses these keys."
        case .blocked: "macOS or most apps already use these keys."
        }
    }
}

/// Key codes: macOS virtual keycodes, plus mouse buttons 3 to 10 as `Key.mouse(n)`.
public enum Key {
    public static let fn = 63, globe = 179
    public static let cmd = 55, rightCmd = 54, shift = 56, rightShift = 60
    public static let opt = 58, rightOpt = 61, ctrl = 59, rightCtrl = 62
    public static let esc = 53, space = 49, tab = 48, delete = 51
    public static let left = 123, right = 124, down = 125, up = 126
    static let a = 0, s = 1, f = 3, h = 4, z = 6, x = 7, c = 8, v = 9, q = 12, w = 13, e = 14, n = 45, m = 46
    static let three = 20, four = 21, five = 23, grave = 50
    static let p = 35

    /// Mouse button `n` (3 = middle, 4 and 5 = side buttons ... 10); CGEvent's buttonNumber is n - 1.
    public static func mouse(_ n: Int) -> Int { 1000 + n }
    public static func mouseButton(_ code: Int) -> Int? { (1003...1010).contains(code) ? code - 1000 : nil }

    /// Right-hand modifiers count as the left one. (Globe's 179 never gets here: the tap ignores it.)
    public static func normal(_ code: Int) -> Int {
        [rightCmd: cmd, rightShift: shift, rightOpt: opt, rightCtrl: ctrl][code] ?? code
    }

    public static func isModifier(_ code: Int) -> Bool { [fn, cmd, shift, opt, ctrl].contains(normal(code)) }

    /// flagsChanged: whether modifier `code` is down, from the event's raw flags (the device-dependent bits
    /// tell left from right). nil for keys we do not track, such as Caps Lock.
    public static func modifierDown(_ code: Int, flags: UInt64) -> Bool? {
        let bit: UInt64? = [ctrl: 0x1, shift: 0x2, rightShift: 0x4, cmd: 0x8, rightCmd: 0x10, opt: 0x20, rightOpt: 0x40,
                            rightCtrl: 0x2000, fn: 0x80_0000][code]
        return bit.map { flags & $0 != 0 }
    }

    /// Any event: true when `code` is a modifier and the event's flags say no key of it is down. Catches
    /// a key-up the tap never saw (secure input hides events), which would otherwise block every chord.
    public static func flagUp(_ code: Int, flags: UInt64) -> Bool {
        let bit: UInt64? = [shift: 0x2_0000, ctrl: 0x4_0000, opt: 0x8_0000, cmd: 0x10_0000, fn: 0x80_0000][normal(code)]
        return bit.map { flags & $0 == 0 } ?? false
    }

    private static let names: [Int: String] = {
        var n: [Int: String] = [fn: "fn", ctrl: "⌃", opt: "⌥", shift: "⇧", cmd: "⌘", esc: "Esc", space: "Space",
                                tab: "Tab", delete: "Delete", 36: "Return", 117: "Forward Delete", left: "←", right: "→",
                                down: "↓", up: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
        let ansi = "A S D F H G Z X C V _ B Q W E R Y T 1 2 3 4 6 5 = 9 7 - 8 0 ] O U [ I P _ L J ' K ; \\ , / N M . _ _ `"
        for (code, name) in ansi.split(separator: " ").enumerated() where name != "_" { n[code] = String(name) }
        for (i, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].enumerated() {
            n[code] = "F\(i + 1)"
        }
        return n
    }()

    /// "fn Space", "⌃ ⌘ V", "Mouse 4": modifiers first, in the macOS order.
    public static func label(_ chord: Set<Int>) -> String {
        let order = [fn, ctrl, opt, shift, cmd]
        let keys = Set(chord.map(normal)).sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        return keys.map { k in mouseButton(k).map { "Mouse \($0)" } ?? names[k] ?? "Key \(k)" }.joined(separator: " ")
    }
}

/// The chord bound to each action, with the Mac defaults and the rules a new chord must pass.
/// Chords are stored normalized (`Key.normal`), so either side of a modifier matches.
public struct Shortcuts: Equatable {
    public static let defaults: [ShortcutAction: Set<Int>] = [
        .ptt: [Key.fn], .handsFree: [Key.fn, Key.space], .dismiss: [Key.esc],
        .pasteLast: [Key.ctrl, Key.cmd, Key.v], .copyLast: [Key.ctrl, Key.cmd, Key.c],
        .polish: [Key.ctrl, Key.cmd, Key.p],
    ]

    /// Our own list of chords that macOS, or nearly every Mac app, already uses.
    static let blocked: Set<Set<Int>> = {
        let (cmd, shift, opt, ctrl, fn) = (Key.cmd, Key.shift, Key.opt, Key.ctrl, Key.fn)
        return [
            [cmd, Key.tab], [cmd, shift, Key.tab], [cmd, Key.grave],                 // app and window switching
            [cmd, Key.space], [ctrl, Key.space], [cmd, opt, Key.space], [ctrl, cmd, Key.space],  // Spotlight, input source, Character Viewer
            [cmd, Key.q], [cmd, Key.w], [cmd, Key.h], [cmd, Key.m], [cmd, shift, Key.q],
            [cmd, opt, Key.esc], [ctrl, cmd, Key.q], [ctrl, cmd, Key.f],              // Force Quit, lock screen, full screen
            [cmd, Key.c], [cmd, Key.v], [cmd, Key.x], [cmd, Key.z], [cmd, shift, Key.z], [cmd, Key.a], [cmd, Key.s],
            [cmd, shift, Key.three], [cmd, shift, Key.four], [cmd, shift, Key.five],  // screenshots
            [ctrl, Key.left], [ctrl, Key.right], [ctrl, Key.up], [ctrl, Key.down],    // Spaces, Mission Control
            [fn, Key.delete], [fn, Key.left], [fn, Key.right], [fn, Key.up], [fn, Key.down],  // forward delete, Home, End, Page Up/Down
            [fn, Key.e], [fn, Key.f], [fn, Key.q], [fn, Key.c], [fn, Key.n], [fn, Key.a],     // Globe shortcuts
        ]
    }()

    public private(set) var bindings: [ShortcutAction: Set<Int>]

    /// Stored actions whose chord failed `problem` (a bare letter, two actions on one chord, a chord a newer
    /// build blocks); they keep the default, and the Shortcuts window says so.
    public private(set) var refused: [ShortcutAction] = []

    /// `stored` is what `stored` returned earlier (UserDefaults), read entry by entry: one bad value keeps only
    /// that action's default. Every stored chord passes `problem`, like a recorded one.
    public init(stored: [String: Any]? = nil) {
        bindings = Self.defaults
        for action in ShortcutAction.allCases {
            guard let value = stored?[action.rawValue] else { continue }
            guard let keys = value as? [Int], !keys.isEmpty, set(Set(keys), for: action) == nil else {
                refused.append(action)
                continue
            }
        }
    }

    public var stored: [String: [Int]] {
        Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value.sorted()) })
    }

    public func chord(_ action: ShortcutAction) -> Set<Int> { bindings[action] ?? [] }

    /// Why `raw` (keys as recorded, right-hand modifiers included) cannot be bound to `action`, or nil.
    public func problem(_ raw: Set<Int>, for action: ShortcutAction) -> ChordProblem? {
        let chord = Set(raw.map(Key.normal))
        if raw.count > 3 { return .tooManyKeys }
        let hasModifier = raw.contains(where: Key.isModifier) || raw.contains { Key.mouseButton($0) != nil }
        // Esc alone is the one bare key allowed, and only for cancel.
        if !hasModifier, !(action == .dismiss && chord == [Key.esc]) { return .noModifier }
        if chord.count < raw.count { return .leftRightSame }
        let modifiers = chord.filter(Key.isModifier), keys = chord.subtracting(modifiers)
        if !keys.contains(where: { Key.mouseButton($0) != nil }) {
            // A lone ⇧, ⌥, ⌘ or ⌃ is pressed all day (and either side would match until chords are side-specific).
            if keys.isEmpty, modifiers.count == 1, modifiers != [Key.fn] { return .typing }
            // ⇧ or ⌥ with a key types a character (⌥L is @ on a German layout).
            if !keys.isEmpty, !modifiers.isEmpty, modifiers.isSubset(of: [Key.shift, Key.opt]) { return .typing }
            // ⌘ with one key is some app's shortcut (⌘T, ⌘N, ⌘F, ...).
            if !keys.isEmpty, modifiers == [Key.cmd] { return .blocked }
        }
        if Self.blocked.contains(chord) { return .blocked }
        if bindings.contains(where: { $0.key != action && $0.value == chord }) { return .inUse }
        // A chord holding the hold chord would start a recording before it completes, and the reverse; only
        // hands-free may extend it (fn+Space promotes the hold).
        if action != .handsFree, bindings.contains(where: { other in
            other.key != action && other.key != .handsFree
                && (action == .ptt ? chord.isStrictSubset(of: other.value) : other.key == .ptt && other.value.isStrictSubset(of: chord))
        }) { return .inUse }
        return nil
    }

    /// Binds `raw` when it passes `problem`; returns the problem otherwise.
    @discardableResult
    public mutating func set(_ raw: Set<Int>, for action: ShortcutAction) -> ChordProblem? {
        if let p = problem(raw, for: action) { return p }
        bindings[action] = Set(raw.map(Key.normal))
        return nil
    }

    public mutating func reset() { bindings = Self.defaults }

    /// The action whose chord is exactly the held set.
    public func action(held: Set<Int>) -> ShortcutAction? {
        let keys = Set(held.map(Key.normal))
        return ShortcutAction.allCases.first { bindings[$0] == keys }
    }
}

/// What the key router tells the app.
public enum KeyInput: Equatable {
    case pttDown, pttUp, toggle, dismiss, pasteLast, copyLast, openNotes
    case polish               // F45
    case otherKey             // during a hold or a dictation, a key or button went down that completes no shortcut
    case recorded(Set<Int>)   // the chord the Shortcuts window asked for, as pressed
}

/// Tracks the held keys and buttons, turns them into shortcut inputs, and decides which events the
/// tap drops so the front app never sees them. Decides from its own state only (the tap callback must be fast).
public struct KeyRouter {
    public var shortcuts: Shortcuts
    public private(set) var held: Set<Int> = []   // as pressed, right-hand modifiers included
    private var dropped: Set<Int> = []            // their down was dropped, so their repeats and up are too
    private var pttHeld = false
    private var captured: Set<Int>?               // set while the Shortcuts window records a chord

    public init(shortcuts: Shortcuts = Shortcuts()) { self.shortcuts = shortcuts }

    public var isRecording: Bool { captured != nil }
    /// The next chord pressed (everything held until all keys are up) comes back as `.recorded` and fires nothing.
    public mutating func record() { captured = [] }
    public mutating func stopRecording() { captured = nil }

    /// One key or mouse button went down or up. `active`: a dictation or a transcription is running.
    /// `canSwallow`: the tap can drop events (Accessibility). Returns the inputs and whether to drop the event.
    public mutating func key(_ code: Int, down: Bool, active: Bool, canSwallow: Bool) -> (inputs: [KeyInput], swallow: Bool) {
        let before = Set(held.map(Key.normal))
        if !down {
            held.remove(code)
            let swallow = dropped.remove(code) != nil
            if let c = captured, held.isEmpty, !c.isEmpty {
                captured = nil
                return ([.recorded(c)], swallow)
            }
            let now = Set(held.map(Key.normal))
            if pttHeld, now != before, shortcuts.chord(.ptt).contains(Key.normal(code)) {
                pttHeld = false
                return ([.pttUp], swallow)  // releasing any key of the hold chord ends the hold
            }
            return ([], swallow)
        }
        held.insert(code)
        // Key repeat, or the twin of a key already held (Globe with fn, both Command keys).
        if Set(held.map(Key.normal)) == before { return ([], dropped.contains(code)) }
        let drop = canSwallow && !Key.isModifier(code)
        if captured != nil {
            captured?.insert(code)
            if drop { dropped.insert(code) }
            return ([], drop)
        }
        guard let action = shortcuts.action(held: held), action != .dismiss || active else {
            return (pttHeld || active ? [.otherKey] : [], false)  // only a running hold or dictation cares
        }
        if drop { dropped.insert(code) }
        switch action {
        case .ptt:
            pttHeld = true
            return ([.pttDown], drop)
        case .handsFree: return ([.toggle], drop)
        case .dismiss: return ([.dismiss], drop)
        case .pasteLast: return ([.pasteLast], drop)
        case .copyLast: return ([.copyLast], drop)
        case .openNotes: return ([.openNotes], drop)
        case .polish: return ([.polish], drop)
        }
    }

    /// After the tap was off, key-ups may have been lost: every held key that `isUp` reports up is released.
    public mutating func releaseStale(isUp: (Int) -> Bool) -> [KeyInput] {
        held.sorted().filter(isUp).flatMap { key($0, down: false, active: false, canSwallow: false).inputs }
    }
}

/// The text paste-last and copy-last use: the newest history row with text (a paste that did not land is the
/// main case). Rows without text (too short, no speech) are skipped, and so is a dictation cancelled with Esc:
/// the user threw it away, so paste last gives the one before it, as Wispr does. A row switched to Show raw
/// gives its raw words (F48).
public func lastText(in rows: [HistoryEntry]) -> String? {
    rows.filter { !$0.text.isEmpty && $0.outcome != .cancelled }.max { $0.createdAt < $1.createdAt }?.shownText
}
