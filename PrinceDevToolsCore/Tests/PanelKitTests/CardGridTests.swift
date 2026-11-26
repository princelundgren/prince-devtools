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

    private static func actionCard(_ title: String, detail: String?, gauge: Double?) -> some View {
        CardView(
            title: title, tone: .info, value: "1", detail: detail, gauge: gauge, accessibilityLabel: title,
            action: CardAction(accessibilityHint: "Opens it", perform: {}))
    }

    private func lay(_ grid: some View) {
        let rendered = ImageRenderer(content: grid)
        rendered.proposedSize = ProposedViewSize(width: 288, height: nil)
        XCTAssertNotNil(rendered.nsImage)
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

    func testACardWithAnActionKeepsThePlainCardsSize() throws {
        let frames = Frames()
        let grid = CardGrid(spacing: 8) {
            Self.card("Plain", detail: "detail", gauge: nil)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("grid")) }) {
                    frames.byTitle["Plain"] = $0
                }
            Self.actionCard("Action", detail: "detail", gauge: nil)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("grid")) }) {
                    frames.byTitle["Action"] = $0
                }
        }
        .coordinateSpace(.named("grid"))
        lay(grid)

        let plain = try XCTUnwrap(frames.byTitle["Plain"])
        let action = try XCTUnwrap(frames.byTitle["Action"])
        XCTAssertEqual(action.size, plain.size)
        XCTAssertEqual(action.origin, CGPoint(x: 148, y: 0))
    }

    func testACardWithAnActionLooksLikeThePlainCard() throws {
        let plain = CardView(
            title: "Card", tone: .green, value: "1", detail: "detail", gauge: nil, accessibilityLabel: "Card")
        let action = CardView(
            title: "Card", tone: .green, value: "1", detail: "detail", gauge: nil, accessibilityLabel: "Card",
            action: CardAction(accessibilityHint: "Opens it", perform: {}))

        let plainImage = try render(plain)
        let actionImage = try render(action)

        XCTAssertEqual(actionImage.size, plainImage.size)
        // Two renders can differ by one alpha level at an anti-aliased edge.
        let largestDifference = zip(actionImage.bitmap, plainImage.bitmap).map { abs(Int($0) - Int($1)) }.max()
        XCTAssertLessThanOrEqual(largestDifference ?? .max, 1)
    }

    /// The card drawn 140 points wide: its size in pixels and its bitmap.
    private func render(_ card: some View) throws -> (size: CGSize, bitmap: Data) {
        let image = try XCTUnwrap(ImageRenderer(content: card.frame(width: 140)).cgImage)
        let bitmap = try XCTUnwrap(image.dataProvider?.data) as Data
        return (CGSize(width: image.width, height: image.height), bitmap)
    }

    func testFiveCardsMakeThreeRowsTheLastWithOne() throws {
        let frames = Frames()
        let titles = ["Memory", "CPU", "Disk", "Processes", "Servers"]
        let grid = CardGrid(spacing: 8) {
            ForEach(titles, id: \.self) { title in
                Self.card(title, detail: title == "Disk" ? nil : "detail", gauge: title == "Processes" ? 0.2 : nil)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("grid")) }) {
                        frames.byTitle[title] = $0
                    }
            }
        }
        .coordinateSpace(.named("grid"))
        .onGeometryChange(for: CGSize.self, of: \.size) { frames.grid = $0 }
        lay(grid)

        XCTAssertEqual(frames.byTitle.count, 5)
        let height = try XCTUnwrap(frames.byTitle["Memory"]?.height)
        XCTAssertEqual(Set(frames.byTitle.values.map(\.size)), [CGSize(width: 140, height: height)])
        XCTAssertEqual(frames.byTitle["Servers"]?.origin, CGPoint(x: 0, y: 2 * (height + 8)))
        XCTAssertEqual(frames.grid, CGSize(width: 288, height: 3 * height + 16))
    }
}
