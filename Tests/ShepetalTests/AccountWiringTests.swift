import Foundation
import XCTest
@testable import Shepetal

/// The app delegate cannot run in a test (it puts the 🤫 panel on screen), so these pin the account wiring in
/// App.swift by its source: the fn gate before the gesture runs, the dictation check given to the license
/// timer, and the menu items. Plus the speech error text the UI shows.
final class AccountWiringTests: XCTestCase {
    private func app() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Shepetal/App.swift").standardizedFileURL, encoding: .utf8)
    }

    func testFnIsGatedBeforeTheGestureRuns() throws {
        let src = try app()
        let fn = try XCTUnwrap(src.range(of: "private func fn(_ down: Bool) {"))
        let body = String(src[fn.upperBound...].prefix(600))
        let gate = try XCTUnwrap(body.range(of: "if down, dictation?.gesture.state == .idle, !Account.shared.allowFnDown() { return }"),
                                 "the fn gate is gone from fn(_:)")
        let run = try XCTUnwrap(body.range(of: "run { down ? $0.fnDown(at: t) : $0.fnUp(at: t) }"))
        XCTAssertLessThan(gate.lowerBound, run.lowerBound, "the gate must come before the gesture")
    }

    func testLicenseTimerKnowsWhenADictationRuns() throws {
        let src = try app()
        XCTAssertTrue(src.contains("Account.shared.start(isDictating: { [weak self] in self?.busy == true || (self?.dictation?.gesture.state ?? .idle) != .idle },"),
                      "isDictating must cover recording (gesture) and transcribing (busy)")
        XCTAssertTrue(src.contains("Account.shared.menuItems().forEach(menu.addItem)"))
    }

    func testOnlyOurOwnSpeechErrorTextReachesTheUI() {
        let fluid = NSError(domain: "FluidAudio", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "ASR model 'x' not found at: /m/parakeet-tdt-0.6b-v3-coreml"])
        XCTAssertEqual(SpeechError(plain: fluid, "On-device speech recognition could not start").errorDescription,
                       "On-device speech recognition could not start")
        XCTAssertEqual(SpeechError(plain: SpeechError("Microphone access is off"), "x").errorDescription, "Microphone access is off")
    }
}
