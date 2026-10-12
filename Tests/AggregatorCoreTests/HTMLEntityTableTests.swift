import XCTest
@testable import AggregatorCore

/// The generated table of every semicolon-terminated named character reference in the HTML standard.
final class HTMLEntityTableTests: XCTestCase {

    func testTableHoldsTheWholeStandard() {
        XCTAssertGreaterThan(HTMLEntityTable.count, 2000)
    }

    func testEveryNameDecodesToANonEmptyString() {
        for (name, text) in HTMLEntityTable.lookup {
            XCTAssertFalse(text.isEmpty, "&\(name); has an empty replacement")
            let decoded = FeedText.decodeEntities("&\(name);")
            XCTAssertFalse(decoded.isEmpty, name)
            XCTAssertNotEqual(decoded, "&\(name);", "&\(name); was left undecoded")
        }
    }

    func testEveryNameIsLettersAndDigitsOnly() {
        for name in HTMLEntityTable.lookup.keys {
            XCTAssertNotNil(name.range(of: "^[A-Za-z][A-Za-z0-9]*$", options: .regularExpression), name)
        }
    }

    func testSpotChecks() {
        XCTAssertEqual(HTMLEntityTable.replacement(for: "ntilde"), "ñ")
        XCTAssertEqual(HTMLEntityTable.replacement(for: "Ntilde"), "Ñ")
        XCTAssertEqual(HTMLEntityTable.replacement(for: "NotEqualTilde"), "\u{2242}\u{0338}")
        XCTAssertNil(HTMLEntityTable.replacement(for: "notanentity"))
        XCTAssertNil(HTMLEntityTable.replacement(for: "ntilde;"))
    }
}
