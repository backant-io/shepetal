import Foundation

/// The Latin-script view of a meeting held in another script (F123): Cyrillic, Greek, kana and so on, written in
/// Latin letters by Foundation's transliteration. No model, no network. It is computed whenever it is shown, never
/// stored next to the original, so the store keeps one copy of what was said.
public enum Romanize {
    /// True when any letter is outside the Latin script. Digits, punctuation, symbols and Latin letters with
    /// diacritics ("é", "ł", "ß") do not count.
    public static func needsLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { isLetter($0) && !isLatin($0) }
    }

    /// The text in Latin letters ("Привет, мир!" → "Privet, mir!"). Punctuation, digits and Latin text stay as they are.
    public static func latin(_ text: String) -> String {
        guard needsLatin(text) else { return text }
        return text.applyingTransform(.toLatin, reverse: false) ?? text
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// The Latin blocks of Unicode, with the spacing modifier letters (ʼ, ˈ) that Latin text uses.
    private static func isLatin(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0x24F, 0x250...0x2FF, 0x1D00...0x1DBF, 0x1E00...0x1EFF,
             0x2071, 0x207F, 0x2090...0x209C, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFB00...0xFB06,
             0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return true
        default:
            return false
        }
    }
}

public extension MeetingRecord {
    /// The transcript, summary or notes have letters outside the Latin script: the Latin toggle shows.
    var needsLatin: Bool {
        segments.contains { Romanize.needsLatin($0.text) } || Romanize.needsLatin(notes)
            || (summary.map { s in s.texts.contains(where: Romanize.needsLatin) } ?? false)
    }

    /// The same meeting with its segments, summary and notes in Latin letters, for showing, copying and export.
    /// The app name, times and ids stay.
    func inLatin() -> MeetingRecord {
        var r = self
        r.segments = segments.map { var s = $0; s.text = Romanize.latin(s.text); return s }
        r.notes = Romanize.latin(notes)
        r.summary = summary.map { s in
            Summary(overview: Romanize.latin(s.overview), keyPoints: s.keyPoints.map(Romanize.latin),
                    decisions: s.decisions.map(Romanize.latin),
                    actionItems: s.actionItems.map { ActionItem(owner: Romanize.latin($0.owner), task: Romanize.latin($0.task),
                                                                due: Romanize.latin($0.due)) })
        }
        return r
    }
}

private extension Summary {
    var texts: [String] { [overview] + keyPoints + decisions + actionItems.flatMap { [$0.owner, $0.task, $0.due] } }
}
