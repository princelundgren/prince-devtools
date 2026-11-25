import AppKit
import XCTest
@testable import PanelKit

final class PanelToneTests: XCTestCase {
    private let tones: [PanelTone] = [.notKnown, .green, .yellow, .red]

    func testEachToneHasItsOwnSymbol() {
        let names = tones.map(\.symbolName)

        XCTAssertEqual(Set(names).count, 4)
        for name in names {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    func testToneColoursResolve() {
        for name in ["Green", "Yellow", "Red"] {
            XCTAssertNotNil(NSColor(named: name, bundle: .module), name)
        }
    }
}
