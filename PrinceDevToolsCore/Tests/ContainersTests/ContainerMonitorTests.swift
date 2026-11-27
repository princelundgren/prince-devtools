import Foundation
import Synchronization
import XCTest
@testable import Containers

/// A source with one socket whose transport counts its calls and records the base priority of the
/// task each call ran in. Every call answers `.notRunning`, so a scan finishes with no runtimes and
/// its `time` is the number of `now` calls so far. The first call can be held until
/// `releaseFirstCall`, so a test can act while the first scan is still running.
private final class FakeScanner: Sendable {
    struct Values {
        var calls = 0
        var nowCalls = 0
        var priorities: [TaskPriority?] = []
        var holdsFirstCall = false
    }

    private let values = Mutex(Values())
    private let firstCallGate = AsyncStream<Void>.makeStream()

    var calls: Int { values.withLock { $0.calls } }
    var priorities: [TaskPriority?] { values.withLock { $0.priorities } }

    func holdFirstCall() {
        values.withLock { $0.holdsFirstCall = true }
    }

    func releaseFirstCall() {
        firstCallGate.continuation.yield()
    }

    var source: ContainerSource {
        ContainerSource(
            sockets: { [RuntimeSocket(path: "/run/fake.sock", runtime: "Fake")] },
            transport: DockerTransport { _, _, _ throws(SocketReadError) in
                let (call, holds) = self.values.withLock {
                    $0.calls += 1
                    $0.priorities.append(Task.basePriority)
                    return ($0.calls, $0.holdsFirstCall)
                }
                if call == 1, holds {
                    for await _ in self.firstCallGate.stream { break }
                }
                throw .notRunning
            },
            now: {
                Date(timeIntervalSince1970: TimeInterval(self.values.withLock { $0.nowCalls += 1; return $0.nowCalls }))
            })
    }
}

@MainActor
final class ContainerMonitorTests: XCTestCase {
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
        let monitor = ContainerMonitor(source: fake.source)
        await monitor.scansFinished()

        XCTAssertNil(monitor.scan)
        XCTAssertEqual(fake.calls, 0)
    }

    func testPanelOpenScansOnceAndShowsTheCards() async {
        let fake = FakeScanner()
        let monitor = ContainerMonitor(source: fake.source)

        monitor.panelOpened()
        await monitor.scansFinished()

        XCTAssertEqual(fake.calls, 1)
        XCTAssertNotNil(monitor.scan)
        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testShowListScansAndArmsTheTimer() async {
        let fake = FakeScanner()
        let monitor = ContainerMonitor(source: fake.source)

        monitor.showList()
        await monitor.scansFinished()

        XCTAssertEqual(fake.calls, 1)
        XCTAssertNotNil(monitor.scan)
        XCTAssertTrue(monitor.isListShown)
        XCTAssertTrue(monitor.isListTimerArmed)
        monitor.hideList()
    }

    func testTheListsTimerRescansOnTheMainRunLoop() async {
        let fake = FakeScanner()
        let monitor = ContainerMonitor(source: fake.source, listTimerInterval: 0.05)

        let elapsed = await ContinuousClock().measure {
            monitor.showList()
            await waitUntil { fake.calls >= 3 }
        }
        monitor.hideList()

        XCTAssertGreaterThanOrEqual(fake.calls, 3)
        // Timing-dependent: two ticks of 0.05 s take far less than 3 s, even on a loaded runner; a
        // 2 s timer would take 4 s.
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    func testHideListStopsTheTimer() {
        let monitor = ContainerMonitor(source: FakeScanner().source)
        monitor.showList()

        monitor.hideList()

        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testPanelCloseStopsTheTimerAndHidesTheList() {
        let monitor = ContainerMonitor(source: FakeScanner().source)
        monitor.panelOpened()
        monitor.showList()

        monitor.panelClosed()

        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testPanelOpensOnTheCardsAfterTheList() async {
        let monitor = ContainerMonitor(source: FakeScanner().source)
        monitor.panelOpened()
        monitor.showList()
        monitor.panelClosed()

        monitor.panelOpened()
        await monitor.scansFinished()

        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testReopeningWithoutACloseStopsTheListTimer() async {
        let fake = FakeScanner()
        let monitor = ContainerMonitor(source: fake.source)
        monitor.panelOpened()
        monitor.showList()

        monitor.panelOpened()
        await monitor.scansFinished()

        XCTAssertFalse(monitor.isListShown)
        XCTAssertFalse(monitor.isListTimerArmed)
    }

    func testScansRunAtBackgroundPriority() async {
        let fake = FakeScanner()
        let monitor = ContainerMonitor(source: fake.source)

        monitor.panelOpened()
        await monitor.scansFinished()
        monitor.showList()
        await monitor.scansFinished()
        monitor.hideList()

        XCTAssertEqual(fake.priorities, [.background, .background])
    }

    func testAReopenWhileAScanRunsStartsNoneAndShowsThatScansResult() async {
        let fake = FakeScanner()
        fake.holdFirstCall()
        let monitor = ContainerMonitor(source: fake.source)
        monitor.panelOpened()
        await waitUntil { fake.calls > 0 }
        monitor.panelClosed()

        monitor.panelOpened()
        let scanBeforeRelease = monitor.scan
        fake.releaseFirstCall()
        await monitor.scansFinished()

        XCTAssertNil(scanBeforeRelease)
        XCTAssertEqual(fake.calls, 1)
        XCTAssertEqual(monitor.scan?.time, Date(timeIntervalSince1970: 1))
    }

    func testShowingTheListWhileAScanRunsStartsNoneButArmsTheTimer() async {
        let fake = FakeScanner()
        fake.holdFirstCall()
        let monitor = ContainerMonitor(source: fake.source)
        monitor.panelOpened()
        await waitUntil { fake.calls > 0 }

        monitor.showList()
        fake.releaseFirstCall()
        await monitor.scansFinished()
        let isTimerArmed = monitor.isListTimerArmed
        monitor.hideList()

        XCTAssertEqual(fake.calls, 1)
        XCTAssertNotNil(monitor.scan)
        XCTAssertTrue(isTimerArmed)
    }

    func testATimerTickWhileAScanRunsIsSkipped() async {
        let fake = FakeScanner()
        fake.holdFirstCall()
        let monitor = ContainerMonitor(source: fake.source)
        monitor.showList()
        await waitUntil { fake.calls > 0 }

        monitor.listTimerFired()
        fake.releaseFirstCall()
        await monitor.scansFinished()
        let callsWhileHeld = fake.calls
        monitor.listTimerFired()
        await monitor.scansFinished()
        monitor.hideList()

        XCTAssertEqual(callsWhileHeld, 1)
        XCTAssertEqual(fake.calls, 2)
    }
}
