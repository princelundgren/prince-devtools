import XCTest
@testable import SystemHealth

final class HealthTextTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let swedish = Locale(identifier: "sv_SE")

    private func message(_ message: HealthMessage, locale: Locale? = nil) -> String {
        HealthText.message(message, locale: locale ?? english)
    }

    private func culprit(_ culprit: Culprit, locale: Locale? = nil) -> String {
        HealthText.culprit(culprit, locale: locale ?? english)
    }

    private func cards(_ readings: HealthReadings, _ status: HealthStatus, windowMinutes: Int = 5) -> [HealthCard] {
        HealthText.cards(readings, status, windowMinutes: windowMinutes, locale: english)
    }

    private func status(memory: CardState = .green, cpu: CardState = .green, disk: CardState = .green,
                        processes: CardState = .green) -> HealthStatus {
        HealthStatus(memory: memory, cpu: cpu, disk: disk, processes: processes, messages: [])
    }

    func testMessagesUseTheDesignWording() {
        XCTAssertEqual(message(.memory), "Memory pressure is red")
        XCTAssertEqual(message(.cpu(percent: 91.4, windowMinutes: 5)), "CPU avg 5 min is 91 %")
        XCTAssertEqual(message(.thermal(.serious)), "Mac is running hot")
        XCTAssertEqual(message(.thermal(.critical)), "Mac is slowing down from heat")
        XCTAssertEqual(message(.disk(freeBytes: 28_000_000_000)), "28 GB free on the startup disk")
        XCTAssertEqual(message(.processes(count: 3300, limit: 4000)), "3,300 of 4,000 processes in use")
    }

    func testCulpritLines() {
        XCTAssertEqual(culprit(.memory(name: "claude", bytes: 4_400_000_000)), "Top of your processes: claude 4.1 GB")
        XCTAssertEqual(culprit(.cpu(name: "node", percentOfCore: 340)), "Top of your processes: node 340 %")
        XCTAssertEqual(culprit(.processes(name: "node", count: 312)), "Top of your processes: node × 312")
        XCTAssertEqual(culprit(.mostlySystem), "Mostly system processes")
    }

    func testSwedishLocale() {
        let memory = culprit(.memory(name: "claude", bytes: 4_400_000_000), locale: swedish)
        let processes = message(.processes(count: 3300, limit: 4000), locale: swedish)
        XCTAssertTrue(memory.contains("4,1 GB"), memory)
        XCTAssertTrue(processes.contains("3\u{00A0}300"), processes)
        XCTAssertFalse(memory.contains("4.1"), memory)
        XCTAssertFalse(processes.contains("3,300"), processes)
    }

    func testCardsAreInOrderAndOnlyProcessesHaveAGauge() throws {
        let readings = HealthReadings(memory: .normal, cpu: .full(percent: 10, span: .seconds(300)),
                                      diskFreeBytes: 70_000_000_000, processCount: 755, processLimit: 4000)
        let result = cards(readings, status())
        XCTAssertEqual(result.map(\.title), ["Memory", "CPU", "Disk", "Processes"])
        XCTAssertEqual(result.map { $0.gauge == nil }, [true, true, true, false])
        XCTAssertEqual(try XCTUnwrap(result[3].gauge), 755.0 / 4000.0, accuracy: 1e-9)
    }

    func testCardValuesAndDetails() {
        let readings = HealthReadings(memory: .warning, swapUsedBytes: 8_912_000_000,
                                      cpu: .full(percent: 91.4, span: .seconds(300)),
                                      diskFreeBytes: 70_000_000_000, processCount: 755, processLimit: 4000)
        let result = cards(readings, status(memory: .yellow))
        XCTAssertEqual(result.map(\.value), ["Yellow", "91 %", "70 GB free", "755/4,000"])
        XCTAssertEqual(result.map(\.detail), ["Swap 8.3 GB", "avg 5 min", nil, nil])
        XCTAssertEqual(result.map(\.state), [.yellow, .green, .green, .green])
    }

    func testProcessGaugeIsClampedToOne() {
        let readings = HealthReadings(processCount: 5000, processLimit: 4000)
        XCTAssertEqual(cards(readings, status())[3].gauge, 1)
    }

    func testProcessesValueUsesTheLocalesSeparator() {
        let readings = HealthReadings(processCount: 755, processLimit: 4000)
        let result = HealthText.cards(readings, status(), windowMinutes: 5, locale: swedish)
        XCTAssertEqual(result[3].value, "755/4\u{00A0}000")
    }

    func testMemoryCardWithoutSwapHasNoDetail() {
        let result = cards(HealthReadings(memory: .normal), status())
        XCTAssertEqual(result[0].value, "Green")
        XCTAssertNil(result[0].detail)
    }

    func testCardsNotKnown() {
        let notKnown = status(memory: .notKnown, cpu: .notKnown, disk: .notKnown, processes: .notKnown)
        let result = cards(HealthReadings(), notKnown)
        XCTAssertEqual(result.map(\.value), Array(repeating: "Not known yet", count: 4))
        XCTAssertEqual(result.map(\.state), Array(repeating: .notKnown, count: 4))
        XCTAssertEqual(result.map(\.detail), Array(repeating: nil, count: 4))
        XCTAssertEqual(result.map { $0.gauge == nil }, Array(repeating: true, count: 4))
    }

    func testCPUCardWording() {
        func cpuCard(_ average: CPUAverage) -> HealthCard {
            cards(HealthReadings(cpu: average), status())[1]
        }
        let partial = cpuCard(.partial(percent: 40, span: .seconds(120)))
        XCTAssertEqual(partial.value, "40 %")
        XCTAssertEqual(partial.detail, "avg 2 min")
        XCTAssertEqual(cpuCard(.partial(percent: 40, span: .seconds(50))).detail, "avg 1 min")
        XCTAssertEqual(cpuCard(.partial(percent: 40, span: .seconds(20))).detail, "avg 1 min")
        XCTAssertEqual(cpuCard(.full(percent: 40, span: .seconds(340))).detail, "avg 5 min")
    }

    func testCardAccessibilityLabelNamesValueAndState() {
        let readings = HealthReadings(diskFreeBytes: 5_000_000_000)
        let result = cards(readings, status(disk: .red))
        XCTAssertEqual(result[2].accessibilityLabel, "Disk, 5 GB free, red")
    }

    func testAccessibilityLabelIncludesTheDetail() {
        let readings = HealthReadings(memory: .normal, swapUsedBytes: 8_912_000_000)
        XCTAssertEqual(cards(readings, status())[0].accessibilityLabel, "Memory, Green, Swap 8.3 GB")
    }

    func testNotKnownAccessibilityLabelDoesNotRepeatTheValue() {
        let result = cards(HealthReadings(), status(disk: .notKnown))
        XCTAssertEqual(result[2].accessibilityLabel, "Disk, Not known yet")
    }
}
