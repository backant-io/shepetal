import XCTest
import ShepetalCore
@testable import Shepetal

/// F12: Parakeet takes no language, so a dictation in a language the user did not choose comes out in that
/// language. The hint next to 🤫 says so. Apple's text recognizer runs here for real; it is on-device.
final class LanguageHintTests: XCTestCase {
    let mac = modelTier(appleSilicon: true, ramGB: 24)
    let spanish = "Por favor, envía el informe al equipo antes del viernes por la tarde."

    func testAnotherLanguageOnTheStandardEngineGetsTheHint() {
        let hint = Speech.wrongLanguageHint(spanish, languages: ["de", "fr"], tier: mac)
        let name = Locale.current.localizedString(forLanguageCode: "es")!
        XCTAssertEqual(hint, "This sounded like \(name), which is not in your Languages")
    }

    func testNoHintWhenTheTextIsInAChosenLanguage() {
        XCTAssertNil(Speech.wrongLanguageHint("Bitte schicken Sie den Bericht vor Freitagnachmittag an das Team.",
                                              languages: ["de", "fr"], tier: mac))
        XCTAssertNil(Speech.wrongLanguageHint(spanish, languages: ["es-ES"], tier: mac), "a tag of the language")
    }

    func testNoHintWhenItCannotBeRightOrToldApart() {
        XCTAssertNil(Speech.wrongLanguageHint(spanish, languages: [], tier: mac), "Automatic")
        XCTAssertNil(Speech.wrongLanguageHint(spanish, languages: ["en", "ja"], tier: mac), "whisper is told the language")
        XCTAssertNil(Speech.wrongLanguageHint("Hola.", languages: ["de"], tier: mac), "too short")
        // The recognizer reads Estonian as Finnish: an Estonian speaker must not see the hint on every dictation.
        XCTAssertNil(Speech.wrongLanguageHint("Palun saatke aruanne meeskonnale enne reede pärastlõunat.",
                                              languages: ["et"], tier: mac))
    }
}
