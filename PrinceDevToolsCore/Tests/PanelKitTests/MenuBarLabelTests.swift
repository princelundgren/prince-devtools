import XCTest
@testable import PanelKit

final class MenuBarLabelTests: XCTestCase {
    private func message(_ text: String) -> PanelMessage {
        PanelMessage(id: text, text: text, detail: nil, opensActivityMonitor: false)
    }

    func testNoMessagesIsNormal() {
        let label = menuBarLabel(messages: [])

        XCTAssertFalse(label.isAttention)
        XCTAssertEqual(label.accessibilityLabel, "PrinceDevTools")
    }

    func testAnyMessageIsAttentionWithADifferentSymbol() {
        let normal = menuBarLabel(messages: [])
        let label = menuBarLabel(messages: [message("Memory pressure is red"), message("CPU avg 5 min is 91 %")])

        XCTAssertTrue(label.isAttention)
        XCTAssertNotEqual(label.symbolName, normal.symbolName)
        XCTAssertEqual(label.accessibilityLabel, "PrinceDevTools: Memory pressure is red")
    }

    func testBothSymbolsExist() {
        for label in [menuBarLabel(messages: []), menuBarLabel(messages: [message("x")])] {
            XCTAssertNotNil(NSImage(systemSymbolName: label.symbolName, accessibilityDescription: nil))
        }
    }
}
