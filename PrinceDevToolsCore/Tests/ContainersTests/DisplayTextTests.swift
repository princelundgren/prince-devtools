import XCTest
@testable import Containers

final class DisplayTextTests: XCTestCase {
    func testControlAndBidiControlScalarsBecomeReplacementCharacters() {
        XCTAssertEqual(DisplayText.sanitized("web\n\u{202E}\u{1B}[31m"), "web\u{FFFD}\u{FFFD}\u{FFFD}[31m")
    }

    func testLineAndParagraphSeparatorsBecomeReplacementCharacters() {
        XCTAssertEqual(DisplayText.sanitized("a\u{2028}b\u{2029}c"), "a\u{FFFD}b\u{FFFD}c")
    }

    func testOrdinaryTextIsKept() {
        XCTAssertEqual(DisplayText.sanitized("café-db_1 · nginx:latest"), "café-db_1 · nginx:latest")
    }

    func testLongTextIsCutAtACharacterBoundaryWithin1024Bytes() {
        let cut = DisplayText.sanitized("a" + String(repeating: "é", count: 1_000))

        XCTAssertEqual(cut.utf8.count, 1_023)
        XCTAssertEqual(cut, "a" + String(repeating: "é", count: 511))
    }
}
