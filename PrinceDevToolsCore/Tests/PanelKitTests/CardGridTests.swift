import PanelKit
import SwiftUI
import XCTest

@MainActor
final class CardGridTests: XCTestCase {
    private final class Frames {
        var byTitle: [String: CGRect] = [:]
        var grid: CGSize = .zero
    }

    private static func card(_ title: String, detail: String?, gauge: Double?) -> some View {
        CardView(title: title, tone: .green, value: "1", detail: detail, gauge: gauge, accessibilityLabel: title)
    }

    /// Lays out four cards, one without a second line and one with a gauge, in a grid offered
    /// `width`, or no width at all.
    private func layOutFourCards(width: CGFloat? = 288) -> Frames {
        let frames = Frames()
        let grid = CardGrid(spacing: 8) {
            ForEach(["Memory", "CPU", "Disk", "Processes"], id: \.self) { title in
                Self.card(title, detail: title == "Disk" ? nil : "detail", gauge: title == "Processes" ? 0.2 : nil)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("grid")) }) {
                        frames.byTitle[title] = $0
                    }
            }
        }
        .coordinateSpace(.named("grid"))
        .onGeometryChange(for: CGSize.self, of: \.size) { frames.grid = $0 }
        let rendered = ImageRenderer(content: grid)
        rendered.proposedSize = ProposedViewSize(width: width, height: nil)
        XCTAssertNotNil(rendered.nsImage)
        return frames
    }

    func testEveryCardTakesTheSizeOfTheLargest() {
        let frames = layOutFourCards()

        XCTAssertEqual(frames.byTitle.count, 4)
        XCTAssertEqual(Set(frames.byTitle.values.map(\.size.width)), [140])
        XCTAssertEqual(Set(frames.byTitle.values.map(\.size.height)).count, 1, "\(frames.byTitle)")
    }

    func testCardsFillTwoColumnsInOrderWithTheSpacingBetween() throws {
        let frames = layOutFourCards()
        let memory = try XCTUnwrap(frames.byTitle["Memory"])
        let cpu = try XCTUnwrap(frames.byTitle["CPU"])
        let disk = try XCTUnwrap(frames.byTitle["Disk"])
        let processes = try XCTUnwrap(frames.byTitle["Processes"])

        XCTAssertEqual(memory.origin, .zero)
        XCTAssertEqual(cpu.origin, CGPoint(x: 148, y: 0))
        XCTAssertEqual(disk.origin, CGPoint(x: 0, y: memory.maxY + 8))
        XCTAssertEqual(processes.origin, CGPoint(x: 148, y: memory.maxY + 8))
        XCTAssertEqual(frames.grid, CGSize(width: 288, height: 2 * memory.height + 8))
    }

    func testWithNoWidthOfferedEachColumnTakesTheWidestCard() throws {
        let frames = layOutFourCards(width: nil)
        let cardWidth = try XCTUnwrap(frames.byTitle["Memory"]?.width)

        XCTAssertGreaterThan(cardWidth, 1)
        XCTAssertEqual(Set(frames.byTitle.values.map(\.size.width)), [cardWidth])
        XCTAssertEqual(frames.grid.width, 2 * cardWidth + 8)
    }
}
