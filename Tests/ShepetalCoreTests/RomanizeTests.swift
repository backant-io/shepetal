import XCTest
@testable import ShepetalCore

/// F123: meetings held in another script can be read in Latin letters, computed when shown and never stored.
final class RomanizeTests: XCTestCase {
    func testCyrillicGreekAndKanaGoToLatin() {
        XCTAssertEqual(Romanize.latin("Привет, мир!"), "Privet, mir!")
        XCTAssertEqual(Romanize.latin("Добрий день"), "Dobrij denʹ")
        XCTAssertEqual(Romanize.latin("Καλημέρα σας"), "Kalēméra sas")
        XCTAssertEqual(Romanize.latin("こんにちは"), "kon'nichiha")
        XCTAssertEqual(Romanize.latin("カタカナ"), "katakana")
        for s in ["Привет", "Привіт", "Καλημέρα", "こんにちは", "東京", "مرحبا", "שלום"] {
            XCTAssertTrue(Romanize.needsLatin(s), s)
            XCTAssertFalse(Romanize.needsLatin(Romanize.latin(s)), "\(s) → \(Romanize.latin(s))")
        }
    }

    func testLatinWithDiacriticsIsUnchanged() {
        for s in ["Café crème", "Łódź", "Straße", "Ærøskøbing", "naïve façade", "Ðorđe", "ʼapostrophe", "ﬁne", ""] {
            XCTAssertFalse(Romanize.needsLatin(s), s)
            XCTAssertEqual(Romanize.latin(s), s)
        }
    }

    func testMixedTextKeepsItsLatinPart() {
        XCTAssertTrue(Romanize.needsLatin("Kate said да"))
        XCTAssertEqual(Romanize.latin("Kate said да, 100%."), "Kate said da, 100%.")
    }

    func testPunctuationAndDigitsAreKept() {
        let s = "Встреча в 15:30, бюджет — 2,5 млн (до 21.10.26)! «Да»?"
        let l = Romanize.latin(s)
        XCTAssertEqual(l, "Vstreča v 15:30, bûdžet — 2,5 mln (do 21.10.26)! «Da»?")
        let notLetters = { (t: String) in t.unicodeScalars.filter { !CharacterSet.letters.contains($0) }.map(String.init).joined() }
        XCTAssertEqual(notLetters(l), notLetters(s))
        XCTAssertFalse(Romanize.needsLatin("12:30, 2.5 € — 100%!?"), "no letters at all")
    }

    func testARecordIsWrittenInLatinWithoutChangingTheOriginal() {
        let record = MeetingRecord(
            meeting: Meeting(id: "m", app: "Zoom", startedAt: Date(timeIntervalSince1970: 0), meAudioPath: "", othersAudioPath: ""),
            segments: [Segment(speaker: .others, start: 3, end: 5, text: "Бюджет утвердили.")],
            summary: Summary(overview: "Бюджет утвердили.", keyPoints: ["Сроки"], decisions: ["Запуск в пятницу"],
                             actionItems: [ActionItem(owner: "Me", task: "прислать слайды", due: "пятница")]),
            notes: "заметка")
        XCTAssertTrue(record.needsLatin)
        let l = record.inLatin()
        XCTAssertEqual(l.segments, [Segment(speaker: .others, start: 3, end: 5, text: "Bûdžet utverdili.")])
        XCTAssertEqual(l.summary, Summary(overview: "Bûdžet utverdili.", keyPoints: ["Sroki"], decisions: ["Zapusk v pâtnicu"],
                                          actionItems: [ActionItem(owner: "Me", task: "prislatʹ slajdy", due: "pâtnica")]))
        XCTAssertEqual(l.notes, "zametka")
        XCTAssertEqual(l.meeting, record.meeting)
        XCTAssertFalse(l.needsLatin)
        XCTAssertEqual(record.segments.first?.text, "Бюджет утвердили.", "the original is a value and stays")

        var latin = record
        latin.segments = [Segment(speaker: .me, start: 1, end: 2, text: "Plain English.")]
        latin.summary = Summary(overview: "Fine.")
        latin.notes = ""
        XCTAssertFalse(latin.needsLatin)
        latin.notes = "Αθήνα"
        XCTAssertTrue(latin.needsLatin, "notes count too")
    }
}
