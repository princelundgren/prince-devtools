import Foundation
import XCTest
@testable import Containers

final class ContainerTextTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let gibibyte: UInt64 = 1 << 30
    private let mebibyte: UInt64 = 1 << 20

    private func container(
        name: String = "web", memoryBytes: UInt64? = nil, upFor seconds: TimeInterval = 3 * 3600 + 59 * 60
    ) -> Container {
        Container(
            id: name, name: name, image: "nginx:latest", runtime: "OrbStack", created: now - seconds,
            memoryBytes: memoryBytes)
    }

    private func scan(_ containers: [Container], read: [String] = ["OrbStack"], unreadable: [String] = [])
        -> ContainerScan
    {
        ContainerScan(containers: containers, runtimesRead: read, unreadableRuntimes: unreadable, time: now)
    }

    private func memory(_ bytes: UInt64) -> String {
        bytes.formatted(ByteCountFormatStyle(style: .memory, locale: english))
    }

    func testCardBeforeTheFirstScanIsNotKnown() {
        let card = ContainerText.card(nil, locale: english)

        XCTAssertEqual(
            card, ContainerCard(value: "Not known yet", detail: nil, accessibilityLabel: "Containers, Not known yet"))
    }

    func testCardWithNoneRunning() {
        let card = ContainerText.card(scan([]), locale: english)

        XCTAssertEqual(card.value, "None running")
        XCTAssertNil(card.detail)
        XCTAssertEqual(card.accessibilityLabel, "Containers, None running")
    }

    func testCardWithOneRunningWithoutKnownMemory() {
        let card = ContainerText.card(scan([container()]), locale: english)

        XCTAssertEqual(card.value, "1 running")
        XCTAssertNil(card.detail)
    }

    func testCardWithManyShowsTheSumOfTheKnownMemory() {
        let containers = [
            container(name: "a", memoryBytes: gibibyte), container(name: "b", memoryBytes: 512 * mebibyte),
            container(name: "c"),
        ]

        let card = ContainerText.card(scan(containers), locale: english)

        let total = memory(gibibyte + 512 * mebibyte)
        XCTAssertEqual(card.value, "3 running")
        XCTAssertEqual(card.detail, total)
        XCTAssertTrue(total.contains("1.5"), "expected 1.5 GB, got \(total)")
        XCTAssertEqual(card.accessibilityLabel, "Containers, 3 running, \(total)")
    }

    func testCardWithAnUnreadableRuntimeAddsItAfterTheTotal() {
        let one = ContainerText.card(
            scan([container(memoryBytes: gibibyte)], unreadable: ["Podman"]), locale: english)
        let two = ContainerText.card(
            scan([container(memoryBytes: gibibyte)], unreadable: ["Podman", "Colima"]), locale: english)

        XCTAssertEqual(one.detail, "\(memory(gibibyte)), 1 runtime unreadable")
        XCTAssertEqual(two.detail, "\(memory(gibibyte)), 2 runtimes unreadable")
    }

    func testCardWithAnUnreadableRuntimeAndNoTotalShowsOnlyTheRuntimes() {
        let card = ContainerText.card(scan([container()], unreadable: ["Podman"]), locale: english)

        XCTAssertEqual(card.value, "1 running")
        XCTAssertEqual(card.detail, "1 runtime unreadable")
        XCTAssertEqual(card.accessibilityLabel, "Containers, 1 running, 1 runtime unreadable")
    }

    func testCardNeverSaysNoneRunningAloneWhileARuntimeIsUnreadable() {
        let card = ContainerText.card(scan([], unreadable: ["Podman"]), locale: english)

        XCTAssertEqual(card.value, "None running")
        XCTAssertEqual(card.detail, "1 runtime unreadable")
    }

    func testCardWhenNothingCouldBeRead() {
        let card = ContainerText.card(scan([], read: [], unreadable: ["Podman"]), locale: english)

        XCTAssertEqual(card.value, "Can't read")
        XCTAssertNil(card.detail)
        XCTAssertEqual(card.accessibilityLabel, "Containers, Can't read")
    }

    func testRowWording() {
        let row = ContainerText.row(container(memoryBytes: 120 * mebibyte), now: now, locale: english)

        XCTAssertEqual(row.name, "web")
        XCTAssertEqual(row.image, "nginx:latest")
        XCTAssertEqual(row.runtime, "OrbStack")
        XCTAssertEqual(row.up, "3 h")
        XCTAssertEqual(row.memory, memory(120 * mebibyte))
        XCTAssertEqual(row.spokenMemory, memory(120 * mebibyte))
        XCTAssertEqual(row.description, "web, nginx:latest, OrbStack, up 3 hours, \(memory(120 * mebibyte))")
    }

    func testRowWithUnknownMemoryShowsADashAndSpeaksIt() {
        let row = ContainerText.row(container(), now: now, locale: english)

        XCTAssertEqual(row.memory, "—")
        XCTAssertEqual(row.spokenMemory, "memory unknown")
        XCTAssertEqual(row.description, "web, nginx:latest, OrbStack, up 3 hours, memory unknown")
    }

    func testTimeUpInWords() {
        func spoken(_ seconds: TimeInterval) -> String {
            ContainerText.row(container(upFor: seconds), now: now, locale: english).spokenUp
        }

        XCTAssertEqual(spoken(0), "0 minutes")
        XCTAssertEqual(spoken(60), "1 minute")
        XCTAssertEqual(spoken(3599), "59 minutes")
        XCTAssertEqual(spoken(3600), "1 hour")
        XCTAssertEqual(spoken(86400), "1 day")
        XCTAssertEqual(spoken(3 * 86400), "3 days")
    }

    func testUpRoundsDownAndNeverGoesNegative() {
        func up(_ seconds: TimeInterval) -> String {
            ContainerText.row(container(upFor: seconds), now: now, locale: english).up
        }

        XCTAssertEqual(up(59 * 60 + 59), "59 min")
        XCTAssertEqual(up(24 * 3600 - 1), "23 h")
        XCTAssertEqual(up(3 * 24 * 3600 + 3600), "3 d")
        XCTAssertEqual(up(-600), "0 min")
    }

    func testUpAtTheHourAndDayBoundaries() {
        func up(_ seconds: TimeInterval) -> String {
            ContainerText.row(container(upFor: seconds), now: now, locale: english).up
        }

        XCTAssertEqual(up(60 * 60), "1 h")
        XCTAssertEqual(up(24 * 3600), "1 d")
    }

    func testUpFarFromNowDoesNotTrap() {
        func up(createdAt seconds: TimeInterval) -> String {
            let created = Container(
                id: "web", name: "web", image: "nginx:latest", runtime: "OrbStack",
                created: Date(timeIntervalSince1970: seconds), memoryBytes: nil)
            return ContainerText.row(created, now: now, locale: english).up
        }

        XCTAssertEqual(up(createdAt: 1e300), "0 min")
        XCTAssertTrue(up(createdAt: -1e300).hasSuffix(" d"))
    }

    func testMemoryOverInt64MaxDoesNotTrap() {
        let largest = Int64.max.formatted(ByteCountFormatStyle(style: .memory, locale: english))

        let row = ContainerText.row(container(memoryBytes: .max), now: now, locale: english)
        let card = ContainerText.card(scan([container(memoryBytes: .max)]), locale: english)

        XCTAssertEqual(row.memory, largest)
        XCTAssertEqual(card.detail, largest)
    }

    func testCardTotalThatOverflowsSaturates() {
        let half: UInt64 = 1 << 63
        let containers = [container(name: "a", memoryBytes: half), container(name: "b", memoryBytes: half)]

        let card = ContainerText.card(scan(containers), locale: english)

        XCTAssertEqual(card.detail, Int64.max.formatted(ByteCountFormatStyle(style: .memory, locale: english)))
    }

    func testUnreadableLineNamesTheRuntime() {
        XCTAssertEqual(ContainerText.unreadable("Podman"), "Couldn't read Podman")
    }

    func testEmptyListIsLeftOutWhenNothingCouldBeRead() {
        XCTAssertNil(ContainerText.emptyList(scan([], read: [], unreadable: ["Podman"])))
    }

    func testEmptyListWithNoRuntimeAtAll() {
        XCTAssertEqual(ContainerText.emptyList(scan([], read: [])), "No containers running")
    }

    func testEmptyListWithOneRuntimeReadAndOneUnreadable() {
        XCTAssertEqual(
            ContainerText.emptyList(scan([], read: ["OrbStack"], unreadable: ["Podman"])), "No containers running")
    }
}
