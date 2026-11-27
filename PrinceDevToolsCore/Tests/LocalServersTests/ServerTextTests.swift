import Darwin
import Foundation
import XCTest
@testable import LocalServers

final class ServerTextTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let home = "/Users/u"
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func server(
        pid: Int32 = 4242, name: String? = "python3", port: UInt16 = 8000,
        addresses: [String] = ["127.0.0.1", "::1"], folderPath: String? = "/Users/u/src/image-gen",
        isFolderGone: Bool = false, runningFor seconds: TimeInterval = 10 * 3600, isParentGone: Bool = true
    ) -> Server {
        Server(
            pid: pid, name: name, port: port, addresses: addresses, folderPath: folderPath, isFolderGone: isFolderGone,
            startTime: now - seconds, isParentGone: isParentGone)
    }

    private func row(_ server: Server) -> ServerRowText {
        ServerText.row(server, now: now, home: home, locale: english)
    }

    func testCardBeforeTheFirstScanIsNotKnown() {
        let card = ServerText.card(nil, locale: english)

        XCTAssertEqual(card, ServerCard(value: "Not known yet", detail: nil, accessibilityLabel: "Servers, Not known yet"))
    }

    func testCardWithNoServers() {
        let card = ServerText.card([], locale: english)

        XCTAssertEqual(card.value, "None listening")
        XCTAssertNil(card.detail)
    }

    func testCardWithOneServer() {
        XCTAssertEqual(ServerText.card([server(isParentGone: false)], locale: english).value, "1 listening")
    }

    func testCardWithManyAndSomeOrphaned() {
        let servers = (0..<8).map { server(pid: Int32($0), isParentGone: $0 < 3) }

        let card = ServerText.card(servers, locale: english)

        XCTAssertEqual(card.value, "8 listening")
        XCTAssertEqual(card.detail, "3 orphaned")
        XCTAssertEqual(card.accessibilityLabel, "Servers, 8 listening, 3 orphaned")
    }

    func testCardCountUsesTheLocale() {
        let servers = (0..<1234).map { server(pid: Int32($0), isParentGone: false) }

        XCTAssertEqual(ServerText.card(servers, locale: english).value, "1,234 listening")
    }

    func testPortAndPIDAreNotGrouped() {
        let text = row(server(pid: 12345, port: 49151))

        XCTAssertEqual(text.port, ":49151")
        XCTAssertEqual(text.pid, "12345")
        XCTAssertTrue(text.description.hasPrefix("Port 49151, python3, pid 12345,"), text.description)
    }

    func testRowWithoutANameShowsThePID() {
        XCTAssertEqual(row(server(name: nil)).name, "pid 4242")
    }

    func testRowShowsTheFolderByItsLastComponent() {
        XCTAssertEqual(row(server()).folder, "image-gen")
    }

    func testRunningRoundsDown() {
        XCTAssertEqual(row(server(runningFor: 59)).running, "0 min")
        XCTAssertEqual(row(server(runningFor: 3599)).running, "59 min")
        XCTAssertEqual(row(server(runningFor: 10 * 3600 + 59 * 60)).running, "10 h")
        XCTAssertEqual(row(server(runningFor: 3 * 86400 + 5 * 3600)).running, "3 d")
    }

    func testStartTimeInTheFutureReadsZero() {
        XCTAssertEqual(row(server(runningFor: -30)).running, "0 min")
    }

    func testDescriptionNamesEverything() {
        XCTAssertEqual(
            row(server()).description,
            "Port 8000, python3, pid 4242, ~/src/image-gen, listening on 127.0.0.1 and ::1, running 10 hours, "
                + "orphaned")
    }

    func testTimeRunningInWords() {
        func spoken(_ seconds: TimeInterval) -> String { row(server(runningFor: seconds)).spokenRunning }

        XCTAssertEqual(spoken(0), "0 minutes")
        XCTAssertEqual(spoken(60), "1 minute")
        XCTAssertEqual(spoken(3599), "59 minutes")
        XCTAssertEqual(spoken(3600), "1 hour")
        XCTAssertEqual(spoken(86400), "1 day")
        XCTAssertEqual(spoken(3 * 86400), "3 days")
    }

    func testDescriptionLeavesOutOrphanedWhenTheParentRuns() {
        XCTAssertEqual(
            row(server(addresses: ["::"], isParentGone: false)).description,
            "Port 8000, python3, pid 4242, ~/src/image-gen, listening on ::, running 10 hours")
    }

    func testFolderGoneWithAndWithoutPath() {
        let withPath = row(server(isFolderGone: true))
        let withoutPath = row(server(folderPath: nil, isFolderGone: true))

        XCTAssertEqual(withPath.folder, "folder gone")
        XCTAssertTrue(withPath.description.contains(", ~/src/image-gen, folder gone, "), withPath.description)
        XCTAssertEqual(withoutPath.folder, "folder gone")
        XCTAssertTrue(withoutPath.description.contains(", pid 4242, folder gone, "), withoutPath.description)
    }

    func testHomeFolderItselfReadsTilde() {
        XCTAssertTrue(row(server(folderPath: "/Users/u")).description.contains(", ~, "))
    }

    func testStopConfirmationNamesTheServer() {
        XCTAssertEqual(
            ServerText.stopConfirmation(server(pid: 12345, port: 8000), with: .terminate),
            StopConfirmation(
                title: "Stop python3 on port 8000?", message: "PID 12345. It can clean up before it quits.",
                button: "Stop"))
    }

    func testForceStopConfirmationWarnsOfLostWork() {
        let confirmation = ServerText.stopConfirmation(server(name: nil), with: .kill)

        XCTAssertEqual(confirmation.title, "Force stop pid 4242 on port 8000?")
        XCTAssertEqual(confirmation.message, "PID 4242. It stops at once, without cleaning up, and may lose unsaved work.")
        XCTAssertEqual(confirmation.button, "Force Stop")
    }

    func testStopFailures() {
        XCTAssertNil(ServerText.stopFailure(.sent, port: 8000))
        XCTAssertEqual(
            ServerText.stopFailure(.processChanged, port: 8000),
            "The process on port 8000 had already exited, so nothing was stopped.")
        XCTAssertEqual(
            ServerText.stopFailure(.failed(EPERM), port: 8000), "macOS didn't allow stopping the process on port 8000.")
        XCTAssertEqual(
            ServerText.stopFailure(.failed(EIO), port: 8000),
            "The process on port 8000 couldn't be stopped: Input/output error.")
    }

    func testFolderOutsideHomeKeepsItsFullPath() {
        let text = row(server(folderPath: "/Users/uu/app"))

        XCTAssertTrue(text.description.contains(", /Users/uu/app, "), text.description)
    }
}
