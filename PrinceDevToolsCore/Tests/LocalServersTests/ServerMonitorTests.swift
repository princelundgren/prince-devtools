import Foundation
import Synchronization
import XCTest
@testable import LocalServers

/// A source whose `listeningSockets` counts its calls and records the base priority of the task it
/// ran in. The first call returns no sockets, every later one a server on port 3000, and the first
/// can be held until `releaseFirstCall`, so a test can finish scan 2 before scan 1. The hold blocks a
/// thread of the global pool, which the test's concurrency allows for.
private final class FakeScanner: Sendable {
    struct Values {
        var calls = 0
        var priorities: [TaskPriority?] = []
        var holdsFirstCall = false
        var firstCallEntered: CheckedContinuation<Void, Never>?
    }

    private let values = Mutex(Values())
    private let firstCallRelease = DispatchSemaphore(value: 0)

    var calls: Int { values.withLock { $0.calls } }
    var priorities: [TaskPriority?] { values.withLock { $0.priorities } }

    func holdFirstCall() {
        values.withLock { $0.holdsFirstCall = true }
    }

    func releaseFirstCall() {
        firstCallRelease.signal()
    }

    /// Returns once the held first call is inside `listeningSockets`.
    func firstCallReached() async {
        await withCheckedContinuation { continuation in
            values.withLock {
                if $0.calls > 0 { continuation.resume() } else { $0.firstCallEntered = continuation }
            }
        }
    }

    var source: ServerSource {
        var processes = FakeProcesses()
        processes.listen(pid: 10, port: 3000)
        var source = processes.source
        let sockets = processes.sockets
        source.listeningSockets = {
            let (call, holds) = self.values.withLock {
                $0.calls += 1
                $0.priorities.append(Task.basePriority)
                $0.firstCallEntered?.resume()
                $0.firstCallEntered = nil
                return ($0.calls, $0.holdsFirstCall)
            }
            if call == 1 {
                if holds { self.firstCallRelease.wait() }
                return []
            }
            return sockets
        }
        return source
    }
}

@MainActor
final class ServerMonitorTests: XCTestCase {
    private func makeMonitor(_ fake: FakeScanner) -> ServerMonitor {
        ServerMonitor(source: fake.source)
    }

    /// Polls until `condition` holds; the scan being waited for runs off the main actor.
    private func waitUntil(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 2000 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testNothingIsScannedBeforeThePanelOpens() async {
        let fake = FakeScanner()
        let monitor = makeMonitor(fake)
        await monitor.scansFinished()

        XCTAssertNil(monitor.scan)
        XCTAssertEqual(fake.calls, 0)
    }

    func testPanelOpenScansOnceAndShowsTheCards() async {
        let fake = FakeScanner()
        let monitor = makeMonitor(fake)

        monitor.panelOpened()
        await monitor.scansFinished()

        XCTAssertEqual(fake.calls, 1)
        XCTAssertNotNil(monitor.scan)
        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testShowListScansAndArmsTheTimer() async {
        let fake = FakeScanner()
        let monitor = makeMonitor(fake)

        monitor.showList()
        await monitor.scansFinished()

        XCTAssertEqual(fake.calls, 1)
        XCTAssertNotNil(monitor.scan)
        XCTAssertTrue(monitor.isListShown)
        XCTAssertTrue(monitor.isListTimerArmed)
        monitor.hideList()
    }

    func testHideListStopsTheTimer() {
        let monitor = makeMonitor(FakeScanner())
        monitor.showList()

        monitor.hideList()

        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testPanelCloseStopsTheTimerAndHidesTheList() {
        let monitor = makeMonitor(FakeScanner())
        monitor.panelOpened()
        monitor.showList()

        monitor.panelClosed()

        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testPanelOpensOnTheCardsAfterTheList() async {
        let fake = FakeScanner()
        let monitor = makeMonitor(fake)
        monitor.panelOpened()
        monitor.showList()
        monitor.panelClosed()
        await monitor.scansFinished()
        let callsBefore = fake.calls

        monitor.panelOpened()
        await monitor.scansFinished()

        XCTAssertEqual(fake.calls, callsBefore + 1)
        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testReopeningWithoutACloseStopsTheListTimer() async {
        let fake = FakeScanner()
        let monitor = makeMonitor(fake)
        monitor.panelOpened()
        monitor.showList()

        monitor.panelOpened()
        await monitor.scansFinished()

        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testATimerTickWhileAScanRunsStartsNone() async {
        let fake = FakeScanner()
        fake.holdFirstCall()
        let monitor = makeMonitor(fake)
        monitor.showList()
        await fake.firstCallReached()

        monitor.listTimerFired()
        fake.releaseFirstCall()
        await monitor.scansFinished()
        XCTAssertEqual(fake.calls, 1)

        monitor.listTimerFired()
        await monitor.scansFinished()
        XCTAssertEqual(fake.calls, 2)
        monitor.hideList()
    }

    func testStopReportsItsResultAndScansAgain() async {
        let fake = FakeScanner()
        let monitor = makeMonitor(fake)
        monitor.panelOpened()
        await monitor.scansFinished()
        let callsBefore = fake.calls
        // Not pid 10's start time, so the stop is refused before any signal is sent.
        let server = Server(
            pid: 10, name: nil, port: 3000, addresses: ["::"], folderPath: nil, isFolderGone: true,
            startTime: FakeProcesses.epoch - 60, isParentGone: false)

        let result = monitor.stop(server, with: .terminate)
        await monitor.scansFinished()

        XCTAssertEqual(result, .processChanged)
        XCTAssertEqual(fake.calls, callsBefore + 1)
    }

    func testScansRunAtBackgroundPriority() async {
        let fake = FakeScanner()
        let monitor = makeMonitor(fake)

        monitor.panelOpened()
        monitor.showList()
        await monitor.scansFinished()
        monitor.hideList()

        XCTAssertEqual(fake.priorities, [.background, .background])
    }

    func testAnOlderScanFinishingLateIsDropped() async {
        let fake = FakeScanner()
        fake.holdFirstCall()
        let monitor = makeMonitor(fake)
        monitor.panelOpened()
        await fake.firstCallReached()

        monitor.panelOpened()
        await waitUntil { monitor.scan != nil }
        fake.releaseFirstCall()
        await monitor.scansFinished()

        XCTAssertEqual(monitor.scan?.servers.count, 1)
    }
}
