import XCTest
import ShepetalCore
@testable import Shepetal

/// F37: Settings shows each style's example for each kind of app, so the user sees what a pick does
/// before dictating. An example a style leaves unchanged would show nothing to choose between.
final class StylesSettingsTests: XCTestCase {
    func testEveryPickShowsADifferentExample() {
        for category in AppCategory.allCases {
            XCTAssertEqual(Styles.apply(.formal, to: category.example), category.example, "Formal shows it as written")
            let shown = Style.allCases.map { Styles.apply($0, to: category.example) }
            XCTAssertEqual(Set(shown).count, Style.allCases.count, "\(category.title): \(shown)")
        }
    }

    /// The four pickers in the order the triage gives, with one title each.
    func testPickerTitles() {
        XCTAssertEqual(AppCategory.allCases.map(\.title), ["Work messages", "Personal messages", "Email", "Other apps"])
        XCTAssertEqual(Style.allCases.map(\.title), ["Formal", "Casual", "Very casual", "Excited"])
    }
}
