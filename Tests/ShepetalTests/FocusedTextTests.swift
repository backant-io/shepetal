import AppKit
import XCTest
@testable import Shepetal
import ShepetalCore

/// Reading the cursor's context from the focused field. The field is a fake (an app's answers to the AX
/// attributes) or a text view's own accessibility answers; no AX call is made and no other app is touched.
final class FocusedTextTests: XCTestCase {
    let nbsp = InsertionRules.nbsp
    var logged: [String] = []

    /// A field that answers `answers`, and AXStringForRange from `text` unless `string` says otherwise.
    func field(_ answers: [String: CFTypeRef], role: String = "AXTextArea",
               string: ((CFRange) -> String?)? = nil) -> FocusedText.Field {
        var answers = answers
        answers[kAXRoleAttribute] = role as CFString
        let text = answers[kAXValueAttribute] as? String
        return FocusedText.Field(get: { answers[$0].map { (.success, $0) } ?? (.noValue, nil) },
                                 string: string ?? { r in text.map { ($0 as NSString).substring(with: NSRange(location: r.location, length: r.length)) } })
    }

    func range(_ location: Int, _ length: Int = 0) -> AXValue {
        var r = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &r)!
    }

    func context(_ f: FocusedText.Field) -> FocusedText.Context {
        FocusedText.context(f, log: { [unowned self] in logged.append($0) })
    }

    func fit(_ dictated: String, _ c: FocusedText.Context) -> String {
        InsertionRules.fit(dictated, before: c.before, after: c.after, selected: c.selected)
    }

    func testSplitsAtTheCursorAndSelection() {
        XCTAssertTrue(FocusedText.split("Please", NSRange(location: 6, length: 0)) == ("Please", ""))
        XCTAssertTrue(FocusedText.split("Send the draft today.", NSRange(location: 9, length: 5)) == ("Send the ", " today."))
        XCTAssertEqual(FocusedText.selection("Send the draft today.", NSRange(location: 9, length: 5)), "draft")
    }

    // A range outside the text is stale or wrong. Guessing the cursor from it (the old clamp put it at the end)
    // would change the case and punctuation on a guess, so it counts as unreadable: no context, no selection.
    func testRangeOutsideTheTextGivesNoContext() {
        for r in [NSRange(location: 40, length: 0), NSRange(location: 3, length: 9), NSRange(location: NSNotFound, length: 0),
                  NSRange(location: -1, length: 0)] {
            XCTAssertTrue(FocusedText.split("Please", r) == ("", ""), "\(r)")
            XCTAssertEqual(FocusedText.selection("Please", r), "", "\(r)")
        }
        let c = context(field([kAXValueAttribute: "Please" as CFString, kAXSelectedTextRangeAttribute: range(40)]))
        XCTAssertTrue(c == ("", "", ""))
        XCTAssertEqual(logged, ["AXTextArea: selection 40+0 outside its 6 characters, text goes in as dictated"])
    }

    // M-INS-1 through AppKit's own answers, the ones TextEdit's text view gives over AX: the context is read,
    // so a dictation mid-sentence is fitted, not inserted as dictated.
    @MainActor
    func testTextViewFieldIsReadAndTheDictationFitsTheCursor() {
        let view = NSTextView()
        view.string = "Please"
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertEqual(fit("Send the report today.", context(FocusedText.Field(view))), " send the report today.")

        view.string = "Type Please, leave the cursor right after it."
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "the cursor").location, length: 0))
        XCTAssertEqual(fit("The cursor.", context(FocusedText.Field(view))), "the cursor" + nbsp)

        view.string = "Send the draft today."
        view.setSelectedRange(NSRange(location: 9, length: 5))
        let c = context(FocusedText.Field(view))
        XCTAssertTrue(c == ("Send the ", " today.", "draft"))
        XCTAssertEqual(fit("Final version.", c), "final version")

        // Ranges count UTF-16 units, as NSString does: an emoji before the cursor does not shift it.
        view.string = "Hi 👋 there"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        XCTAssertEqual(context(FocusedText.Field(view)).before, "Hi 👋 there")
        XCTAssertEqual(logged.last, "AXTextArea, 11 characters, selection 11+0")
    }

    /// Electron (VS Code, Slack, Obsidian) before its AX tree is built: the focused element has no text.
    final class ElectronApp {
        var tree = false
        func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
            guard attribute == "AXManualAccessibility", CFEqual(value, kCFBooleanTrue) else { return .attributeUnsupported }
            tree = true
            return .success
        }
    }

    // Pavel's notes (M-INS-1, 2026-10-21) read "leave The cursor.the cursor": said with the cursor before "the cursor",
    // it went in as dictated, as every dictation into an Electron app did. Asked for its tree at dictation start, the
    // app gives the text, and the dictation fits.
    func testElectronFieldIsReadOnceItsTreeIsAskedFor() {
        let text = "leave the cursor right after it"
        let app = ElectronApp()
        let electron = { [unowned self] in
            app.tree ? field([kAXValueAttribute: text as CFString, kAXSelectedTextRangeAttribute: range(6)])
                     : field([:], role: "AXGroup")
        }
        XCTAssertEqual(fit("The cursor.", context(electron())), "The cursor.")
        XCTAssertEqual(logged, ["AXGroup: AXSelectedTextRange unreadable (AX -25212), text goes in as dictated"])

        FocusedText.askForTree(app.set)
        XCTAssertEqual(fit("The cursor.", context(electron())), "the cursor" + nbsp)
    }

    // An app that answers AXSelectedTextRange with something other than a range must not crash Shepetal:
    // the text goes in as dictated.
    func testRangeOfTheWrongTypeIsUnreadableNotACrash() {
        var point = CGPoint(x: 1, y: 2)
        for wrong: CFTypeRef in ["6" as CFString, AXValueCreate(.cgPoint, &point)!, 6 as CFNumber] {
            XCTAssertTrue(context(field([kAXValueAttribute: "Please" as CFString, kAXSelectedTextRangeAttribute: wrong])) == ("", "", ""))
        }
        XCTAssertEqual(logged.count, 3)
        XCTAssertTrue(logged.allSatisfy { $0.hasPrefix("AXTextArea: AXSelectedTextRange unreadable") }, "\(logged)")
    }

    // Some fields' AXValue is not their text (missing, attributed, or a part of it). AXNumberOfCharacters counts in
    // the range's units, so AXStringForRange over that many characters is the text.
    func testValueThatIsNotTheTextIsReadByLength() {
        let full = "Please"
        let byLength = { (r: CFRange) in (full as NSString).substring(with: NSRange(location: r.location, length: r.length)) }
        for value: CFTypeRef? in [nil, NSAttributedString(string: full), "Pl" as CFString] {
            var answers: [String: CFTypeRef] = [kAXSelectedTextRangeAttribute: range(6), kAXNumberOfCharactersAttribute: 6 as CFNumber]
            answers[kAXValueAttribute] = value
            XCTAssertEqual(fit("Send it.", context(field(answers, string: byLength))), " send it.", "\(String(describing: value))")
        }
        // No string by range either: unreadable.
        XCTAssertTrue(context(field([kAXSelectedTextRangeAttribute: range(6), kAXNumberOfCharactersAttribute: 6 as CFNumber],
                                    string: { _ in nil })) == ("", "", ""))
        XCTAssertEqual(logged.last, "AXTextArea: AXValue is not its 6 characters, text goes in as dictated")
    }

    // A range inside the text can still be wrong: stale, or counted on another node. The selected text the app
    // reports says where the selection really is when it occurs once; otherwise nothing is guessed.
    func testRangeInsideTheTextThatDisagreesWithTheSelectedText() {
        let text = "Send the draft today." as CFString
        let stale = context(field([kAXValueAttribute: text, kAXSelectedTextRangeAttribute: range(0, 0),
                                   kAXSelectedTextAttribute: "draft" as CFString]))
        XCTAssertTrue(stale == ("Send the ", " today.", "draft"))
        XCTAssertEqual(fit("Final version.", stale), "final version")

        let twice = context(field([kAXValueAttribute: "the cat and the dog" as CFString, kAXSelectedTextRangeAttribute: range(4, 3),
                                   kAXSelectedTextAttribute: "the" as CFString]))
        XCTAssertTrue(twice == ("", "", ""))
        let none = context(field([kAXValueAttribute: text, kAXSelectedTextRangeAttribute: range(9, 5),
                                  kAXSelectedTextAttribute: "" as CFString]))
        XCTAssertTrue(none == ("", "", ""))
        XCTAssertEqual(logged.suffix(2), Array(repeating: "AXTextArea: AXSelectedText does not match AXSelectedTextRange, text goes in as dictated", count: 2))
    }

    // The app's own text around the cursor (AXStringForRange) differs from AXValue: the value is another node's
    // text, so the cursor in it is not where the user clicked.
    func testValueThatDisagreesWithTheTextAtTheCursorIsUnreadable() {
        let c = context(field([kAXValueAttribute: "Please" as CFString, kAXSelectedTextRangeAttribute: range(6)],
                              string: { _ in "Dear team" }))
        XCTAssertTrue(c == ("", "", ""))
        XCTAssertEqual(logged, ["AXTextArea: AXStringForRange does not match AXValue at the cursor, text goes in as dictated"])
    }

    // An empty read looks like an empty field. It is logged as one, so a hand test can tell it from a failed read.
    func testEmptyReadIsLogged() {
        XCTAssertTrue(context(field([kAXValueAttribute: "" as CFString, kAXSelectedTextRangeAttribute: range(0)])) == ("", "", ""))
        XCTAssertEqual(logged, ["AXTextArea, 0 characters, selection 0+0"])
    }

    // A field that cannot be read at all gets the text exactly as dictated: no space, case or period guessed.
    // That is right for an empty field and the only safe choice for an unreadable one.
    func testUnreadableFieldInsertsTextAsDictated() {
        let unreadable = FocusedText.Field(get: { _ in (.attributeUnsupported, nil) }, string: { _ in nil })
        XCTAssertEqual(fit("Send the report today.", context(unreadable)), "Send the report today.")
        XCTAssertEqual(logged, ["no role: AXSelectedTextRange unreadable (AX -25205), text goes in as dictated"])
    }

    // The read runs on the main thread. An app that does not answer (each AX call waits for the timeout, 1.5 s
    // measured on macOS 15) is asked once, not once per attribute.
    func testAppThatDoesNotAnswerIsAskedOnce() {
        var calls = 0
        let hung = FocusedText.Field(get: { _ in calls += 1; return (.cannotComplete, nil) }, string: { _ in calls += 1; return nil })
        XCTAssertTrue(context(hung) == ("", "", ""))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(logged, ["no role: no answer (AX -25204), text goes in as dictated"])
    }
}
