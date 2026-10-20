/// What to do with focus before the paste (docs/re/insertion-context.md 2.2 steps 1-2, 4 M1).
/// The app and the focused element are stored when dictation starts, so the text lands in the field
/// the user was in even if focus moved while they spoke.
public enum FocusPlan: Equatable {
    case none              // still in the stored app and element: paste
    case activateAndFocus  // focus moved: bring the app back, focus the element, wait for it, paste
    case activateApp       // the element is gone: bring the app back and paste
    case pasteInPlace      // the app quit: paste wherever focus is now

    public static let focusWait = 0.3  // seconds to wait for the element to take focus

    public static func decide(appRunning: Bool, appIsFront: Bool, elementAlive: Bool, elementIsFocused: Bool) -> FocusPlan {
        guard appRunning else { return .pasteInPlace }
        guard elementAlive else { return appIsFront ? .none : .activateApp }
        return appIsFront && elementIsFocused ? .none : .activateAndFocus
    }
}
