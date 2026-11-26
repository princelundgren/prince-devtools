import Foundation
import Synchronization
import XCTest
@testable import SystemHealth

/// A machine whose readings, clock and pause the test sets. `processUsages` returns "busy-tool"
/// with 1 s more CPU time on every call, so a CPU culprit search finds it at 50 % of a core, and
/// "loop" with `loopCPUTime`, which the test advances; `processCPUTimes` returns the same CPU times
/// by pid, and `processName` their names. A pause adds `busyTicksPerPause` user ticks
/// to the machine's counters. The clock ticks 100 times a second, so 6,000 busy ticks a minute is
/// one core.
private final class FakeSystem: Sendable {
    enum Reading: CaseIterable {
        case memoryLevel, swapUsedBytes, cpuTicks, diskFreeBytes, processCount, processLimit, thermalLevel,
            processUsages, processCPUTimes, processName

        /// The reads that walk processes or name one, which only a scan makes.
        var isScan: Bool { [.processUsages, .processCPUTimes, .processName].contains(self) }
    }

    static let names: [pid_t: String] = [4: "loop", 1: "busy-tool", 2: "node", 3: "node"]

    struct Values {
        var memory: MemoryLevel? = .normal
        var swap: UInt64? = 1_000_000
        var ticks = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        var disk: UInt64? = 100_000_000_000
        var count: Int? = 100
        var limit: Int? = 1000
        var thermal = ThermalLevel.normal
        var now = ContinuousClock.now
        var reads: [Reading: Int] = [:]
        /// The base priority of the task each scan ran in, in order.
        var scanPriorities: [TaskPriority?] = []
        var busyTicksPerPause: UInt32 = 0
        var loopCPUTime: UInt64 = 0
        var holdsPause = false
        var heldPause: CheckedContinuation<Void, Never>?
        var pauseWaiter: CheckedContinuation<Void, Never>?
    }

    let values = Mutex(Values())

    func set(_ change: (inout Values) -> Void) {
        values.withLock { change(&$0) }
    }

    func reads(_ reading: Reading) -> Int {
        values.withLock { $0.reads[reading, default: 0] }
    }

    /// Advances the clock a minute and the CPU counters by `busy` and `idle` ticks.
    func passMinute(busy: UInt32, idle: UInt32) {
        set {
            $0.now += .seconds(60)
            $0.ticks.user &+= busy
            $0.ticks.idle &+= idle
        }
    }

    /// Returns once a culprit search is suspended in `pause`.
    func pauseReached() async {
        await withCheckedContinuation { continuation in
            values.withLock {
                if $0.heldPause == nil { $0.pauseWaiter = continuation } else { continuation.resume() }
            }
        }
    }

    func releasePause() {
        values.withLock {
            $0.now += .seconds(2)
            $0.ticks.user &+= $0.busyTicksPerPause
            $0.heldPause?.resume()
            $0.heldPause = nil
        }
    }

    var source: HealthSource {
        HealthSource(
            memoryLevel: { self.read(.memoryLevel) { $0.memory } },
            swapUsedBytes: { self.read(.swapUsedBytes) { $0.swap } },
            cpuTicks: { self.read(.cpuTicks) { $0.ticks } },
            diskFreeBytes: { self.read(.diskFreeBytes) { $0.disk } },
            processCount: { self.read(.processCount) { $0.count } },
            processLimit: { self.read(.processLimit) { $0.limit } },
            thermalLevel: { self.read(.thermalLevel) { $0.thermal } },
            processUsages: {
                self.set { $0.scanPriorities.append(Task.basePriority) }
                let (call, loopCPUTime) = self.read(.processUsages) {
                    (UInt64($0.reads[.processUsages, default: 0]), $0.loopCPUTime)
                }
                return [
                    ProcessUsage(pid: 4, name: "loop", footprintBytes: 1, cpuTime: loopCPUTime),
                    ProcessUsage(pid: 1, name: "busy-tool", footprintBytes: 100, cpuTime: call * 1_000_000_000),
                    ProcessUsage(pid: 2, name: "node", footprintBytes: 500, cpuTime: 0),
                    ProcessUsage(pid: 3, name: "node", footprintBytes: 300, cpuTime: 0),
                ]
            },
            processCPUTimes: {
                self.set { $0.scanPriorities.append(Task.basePriority) }
                let (call, loopCPUTime) = self.read(.processCPUTimes) {
                    (UInt64($0.reads[.processCPUTimes, default: 0]), $0.loopCPUTime)
                }
                return [4: loopCPUTime, 1: call * 1_000_000_000, 2: 0, 3: 0]
            },
            processName: { pid in self.read(.processName) { _ in Self.names[pid] } },
            now: { self.values.withLock { $0.now } },
            pause: { duration in await self.pause(duration) },
            timebase: MachTimebase(numer: 1, denom: 1),
            ticksPerSecond: 100)
    }

    private func read<Value>(_ reading: Reading, _ value: (Values) -> Value) -> Value {
        values.withLock {
            $0.reads[reading, default: 0] += 1
            return value($0)
        }
    }

    private func pause(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            values.withLock {
                guard $0.holdsPause else {
                    $0.now += duration
                    $0.ticks.user &+= $0.busyTicksPerPause
                    continuation.resume()
                    return
                }
                $0.heldPause = continuation
                $0.pauseWaiter?.resume()
                $0.pauseWaiter = nil
            }
        }
    }
}

@MainActor
final class HealthMonitorTests: XCTestCase {
    private let gigabyte: UInt64 = 1_000_000_000

    /// A monitor on `fake` with its own defaults suite, removed when the test ends, and a
    /// `cpuWindowMinutes` CPU window: 5 unless a test says otherwise.
    private func makeMonitor(_ fake: FakeSystem, cpuWindowMinutes: Int = 5) -> (HealthMonitor, UserDefaults) {
        let suiteName = "HealthMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        var settings = HealthSettings.defaults
        settings.cpuWindowMinutes = cpuWindowMinutes
        settings.save(to: defaults)
        return (HealthMonitor(source: fake.source, defaults: defaults), defaults)
    }

    /// Five minutes at 90 % busy after `start()`, which fills the 5 minute window past 80 %.
    private func driveCPURed(_ monitor: HealthMonitor, _ fake: FakeSystem) {
        for _ in 0..<5 {
            fake.passMinute(busy: 90, idle: 10)
            monitor.tick()
        }
    }

    private func hasMessage(_ monitor: HealthMonitor, _ cause: HealthCause) -> Bool {
        monitor.status.messages.contains { $0.cause == cause }
    }

    func testStartReadsEverythingOnce() async {
        let fake = FakeSystem()
        fake.set { $0.thermal = .serious }
        let (monitor, _) = makeMonitor(fake)

        monitor.start()
        await monitor.culpritSearchesFinished()

        XCTAssertEqual(monitor.status.memory, .green)
        XCTAssertEqual(monitor.status.disk, .green)
        XCTAssertEqual(monitor.status.processes, .green)
        XCTAssertEqual(monitor.status.cpu, .notKnown)
        XCTAssertEqual(monitor.readings.thermal, .serious)
        XCTAssertEqual(monitor.status.messages, [.thermal(.serious)])
        for reading in FakeSystem.Reading.allCases {
            XCTAssertEqual(fake.reads(reading), reading.isScan ? 0 : 1, "\(reading): a thermal message never starts a scan")
        }
        monitor.stop()
    }

    func testTickAppendsACPUSampleAndRereads() {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()

        fake.passMinute(busy: 30, idle: 70)
        fake.set {
            $0.memory = .warning
            $0.disk = 50 * self.gigabyte
            $0.swap = 2_000_000
            $0.count = 200
        }
        monitor.tick()

        guard case let .partial(percent, span) = monitor.readings.cpu else {
            return XCTFail("expected partial, got \(monitor.readings.cpu)")
        }
        XCTAssertEqual(percent, 30, accuracy: 0.001)
        XCTAssertEqual(span, .seconds(60))
        XCTAssertEqual(monitor.readings.memory, .warning)
        XCTAssertEqual(monitor.status.memory, .yellow)
        XCTAssertEqual(monitor.readings.diskFreeBytes, 50 * gigabyte)
        XCTAssertEqual(monitor.readings.swapUsedBytes, 2_000_000)
        XCTAssertEqual(monitor.readings.processCount, 200)
        monitor.stop()
    }

    func testOpeningThePanelTakesAFreshPolledReadingWithoutTouchingCPUOrProcesses() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        fake.set {
            $0.disk = 10 * self.gigabyte
            $0.swap = 3_000_000
        }

        monitor.panelOpened()

        XCTAssertEqual(monitor.readings.diskFreeBytes, 10 * gigabyte)
        XCTAssertEqual(monitor.readings.swapUsedBytes, 3_000_000)
        XCTAssertEqual(monitor.status.disk, .red)
        XCTAssertEqual(fake.reads(.diskFreeBytes), 2)
        XCTAssertEqual(fake.reads(.cpuTicks), 1)
        XCTAssertEqual(fake.reads(.processLimit), 1)
        await monitor.culpritSearchesFinished()
        XCTAssertEqual(fake.reads(.processUsages), 0, "disk has no culprit")
        monitor.stop()
    }

    func testOpeningThePanelOnANewMessageStartsOneCulpritSearch() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        fake.set { $0.memory = .critical }

        monitor.panelOpened()
        await monitor.culpritSearchesFinished()

        XCTAssertEqual(fake.reads(.processUsages), 1)
        monitor.stop()
    }

    func testPanelTickRereadsCountDiskSwapMemoryOnly() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        monitor.panelOpened()

        fake.passMinute(busy: 30, idle: 70)
        fake.set {
            $0.memory = .warning
            $0.disk = 50 * self.gigabyte
            $0.swap = 2_000_000
            $0.count = 200
            $0.limit = 2000
        }
        monitor.panelTick()

        XCTAssertEqual(monitor.readings.memory, .warning)
        XCTAssertEqual(monitor.readings.diskFreeBytes, 50 * gigabyte)
        XCTAssertEqual(monitor.readings.swapUsedBytes, 2_000_000)
        XCTAssertEqual(monitor.readings.processCount, 200)
        XCTAssertEqual(monitor.readings.cpu, .notKnown)
        XCTAssertEqual(monitor.readings.processLimit, 1000)
        XCTAssertEqual(fake.reads(.cpuTicks), 1)

        for _ in 0..<10 { monitor.panelTick() }
        await monitor.culpritSearchesFinished()
        XCTAssertEqual(fake.reads(.processUsages), 0)
        monitor.stop()
    }

    func testWakeDropsCPUAndRereads() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        driveCPURed(monitor, fake)
        await monitor.culpritSearchesFinished()
        XCTAssertTrue(hasMessage(monitor, .cpu))
        XCTAssertNotNil(monitor.culprits[.cpu])

        monitor.sleep()
        fake.set { $0.disk = 50 * self.gigabyte }
        monitor.wake()

        XCTAssertFalse(hasMessage(monitor, .cpu))
        XCTAssertEqual(monitor.readings.cpu, .notKnown)
        XCTAssertEqual(monitor.status.cpu, .notKnown)
        XCTAssertNil(monitor.culprits[.cpu])
        XCTAssertEqual(monitor.readings.diskFreeBytes, 50 * gigabyte)
        monitor.stop()
    }

    func testWakeWithPanelOpenRearmsPanelTimer() {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        monitor.panelOpened()
        XCTAssertTrue(monitor.isPanelTimerArmed)

        monitor.sleep()
        XCTAssertFalse(monitor.isPanelTimerArmed)
        monitor.wake()

        XCTAssertTrue(monitor.isPanelTimerArmed)
        monitor.panelClosed()
        XCTAssertFalse(monitor.isPanelTimerArmed)
        monitor.stop()
    }

    func testSettingsChangeReevaluatesAtOnce() {
        let fake = FakeSystem()
        fake.set { $0.disk = 25 * self.gigabyte }
        let (monitor, defaults) = makeMonitor(fake)
        monitor.settings.diskFreeGB = 20
        monitor.start()
        XCTAssertEqual(monitor.status.disk, .green)

        monitor.settings.diskFreeGB = 30

        XCTAssertEqual(monitor.status.disk, .red)
        XCTAssertEqual(monitor.status.messages, [.disk(freeBytes: 25 * gigabyte)])
        XCTAssertEqual(HealthSettings(reading: defaults).diskFreeGB, 30)
        monitor.stop()
    }

    func testCulpritFoundWhenAMessageAppearsAndOncePerOpening() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()

        fake.set { $0.count = 900 }
        monitor.tick()
        await monitor.culpritSearchesFinished()
        XCTAssertEqual(fake.reads(.processUsages), 1)
        XCTAssertEqual(monitor.culprits[.processes], .processes(name: "node", count: 2))

        monitor.panelOpened()
        for _ in 0..<3 { monitor.panelTick() }
        await monitor.culpritSearchesFinished()
        XCTAssertEqual(fake.reads(.processUsages), 2)

        monitor.panelClosed()
        monitor.panelOpened()
        monitor.tick()
        monitor.panelTick()
        await monitor.culpritSearchesFinished()
        XCTAssertEqual(fake.reads(.processUsages), 3)
        XCTAssertEqual(monitor.culprits[.processes], .processes(name: "node", count: 2))
        monitor.stop()
    }

    func testCulpritClearsWithItsMessage() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        fake.set { $0.count = 900 }
        monitor.tick()
        await monitor.culpritSearchesFinished()
        XCTAssertNotNil(monitor.culprits[.processes])

        fake.set { $0.count = 100 }
        monitor.tick()

        XCTAssertNil(monitor.culprits[.processes])
        monitor.stop()
    }

    /// The CPU culprit after five minutes at 90 %, with `busyTicks` machine ticks
    /// (100 a second) spent during the culprit's 2 s pause, in which busy-tool uses 1 s.
    private func cpuCulprit(
        busyTicksDuringPause busyTicks: UInt32
    ) async -> (Culprit?, processScans: Int, priorities: [TaskPriority?]) {
        let fake = FakeSystem()
        fake.set { $0.busyTicksPerPause = busyTicks }
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        driveCPURed(monitor, fake)
        await monitor.culpritSearchesFinished()
        monitor.stop()
        return (monitor.culprits[.cpu], fake.reads(.processUsages), fake.values.withLock { $0.scanPriorities })
    }

    private func assertBusyTool(_ culprit: Culprit?, line: UInt = #line) {
        guard case let .cpu(name, percentOfCore)? = culprit else {
            return XCTFail("expected a CPU culprit, got \(String(describing: culprit))", line: line)
        }
        XCTAssertEqual(name, "busy-tool", line: line)
        XCTAssertEqual(percentOfCore, 50, accuracy: 0.001, line: line)
    }

    func testCPUCulpritComparesTwoScansTwoSecondsApart() async {
        let (culprit, processScans, priorities) = await cpuCulprit(busyTicksDuringPause: 0)

        XCTAssertEqual(processScans, 2)
        XCTAssertEqual(priorities, [.background, .background])
        assertBusyTool(culprit)
    }

    func testCPUCulpritIsMostlySystemWhenUserProcessesUseUnderHalfTheBusyTime() async {
        let (threeSecondsBusy, _, _) = await cpuCulprit(busyTicksDuringPause: 300)
        XCTAssertEqual(threeSecondsBusy, .mostlySystem)

        let (oneAndAHalfSecondsBusy, _, _) = await cpuCulprit(busyTicksDuringPause: 150)
        assertBusyTool(oneAndAHalfSecondsBusy)
    }

    func testLateCPUCulpritIsDropped() async {
        enum Interruption: CaseIterable { case cpuClears, sleep, stop, panelClosed }

        for interruption in Interruption.allCases {
            let fake = FakeSystem()
            fake.set { $0.holdsPause = true }
            let (monitor, _) = makeMonitor(fake)
            monitor.start()
            if interruption == .panelClosed { monitor.panelOpened() }
            driveCPURed(monitor, fake)
            await fake.pauseReached()

            switch interruption {
            case .cpuClears:
                fake.passMinute(busy: 0, idle: 10_000)
                monitor.tick()
                XCTAssertFalse(hasMessage(monitor, .cpu), "\(interruption)")
            case .sleep: monitor.sleep()
            case .stop: monitor.stop()
            case .panelClosed: monitor.panelClosed()
            }
            fake.releasePause()
            await monitor.culpritSearchesFinished()

            XCTAssertEqual(fake.reads(.processUsages), 2, "\(interruption)")
            XCTAssertNil(monitor.culprits[.cpu], "\(interruption)")
            monitor.stop()
        }
    }

    func testMemoryEventAndThermalChangeReadOnlyTheirLevel() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()

        fake.set {
            $0.memory = .critical
            $0.thermal = .critical
            $0.disk = 10 * self.gigabyte
        }
        monitor.memoryEvent()
        monitor.thermalChanged()
        await monitor.culpritSearchesFinished()

        XCTAssertEqual(monitor.status.messages, [.memory, .thermal(.critical)])
        XCTAssertEqual(monitor.culprits, [.memory: .memory(name: "node", bytes: 500)])
        for reading in FakeSystem.Reading.allCases {
            let expected = switch reading {
            case .memoryLevel, .thermalLevel: 2
            case .processCPUTimes, .processName: 0
            default: 1
            }
            XCTAssertEqual(fake.reads(reading), expected, "\(reading)")
        }
        monitor.stop()
    }

    func testDiskHasNoCulprit() async {
        let fake = FakeSystem()
        fake.set { $0.disk = 10 * self.gigabyte }
        let (monitor, _) = makeMonitor(fake)

        monitor.start()
        monitor.panelOpened()
        await monitor.culpritSearchesFinished()

        XCTAssertEqual(monitor.status.messages, [.disk(freeBytes: 10 * gigabyte)])
        XCTAssertEqual(fake.reads(.processUsages), 0)
        XCTAssertTrue(monitor.culprits.isEmpty)
        monitor.stop()
    }

    /// A minute in which "loop" uses 98 % of a core and the machine one core in all.
    private func passLoopMinute(_ monitor: HealthMonitor, _ fake: FakeSystem) async {
        fake.passMinute(busy: 6000, idle: 66_000)
        fake.set { $0.loopCPUTime += 58_800_000_000 }
        monitor.tick()
        await monitor.busyScanFinished()
    }

    func testAOneMinuteWindowTurnsTheAverageRedAfterOneBusyMinute() {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake, cpuWindowMinutes: 1)
        monitor.start()

        fake.passMinute(busy: 90, idle: 10)
        monitor.tick()

        XCTAssertEqual(monitor.status.messages, [.cpu(percent: 90, windowMinutes: 1)])
        monitor.stop()
    }

    func testAOneMinuteWindowTurnsABusyProcessRedAfterItsFirstWholeMinute() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake, cpuWindowMinutes: 1)
        monitor.start()

        await passLoopMinute(monitor, fake)
        XCTAssertEqual(monitor.status.cpu, .green, "the first scan is only a baseline")
        await passLoopMinute(monitor, fake)

        XCTAssertEqual(monitor.status.messages, [.busyProcess(name: "loop", percentOfCore: 98, windowMinutes: 1)])
        monitor.stop()
    }

    func testOneBusyProcessTurnsCPURedAfterAWholeWindow() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()

        for minute in 1...5 {
            await passLoopMinute(monitor, fake)
            XCTAssertEqual(monitor.status.cpu, .green, "minute \(minute): the first scan is only a baseline")
        }
        await passLoopMinute(monitor, fake)

        XCTAssertEqual(monitor.status.cpu, .red)
        XCTAssertEqual(monitor.status.messages, [.busyProcess(name: "loop", percentOfCore: 98, windowMinutes: 5)])
        XCTAssertEqual(fake.reads(.processCPUTimes), 6)
        XCTAssertEqual(fake.reads(.processUsages), 0, "the busy-process scan reads no paths")
        XCTAssertEqual(fake.reads(.processName), 1, "only the red process is named")
        XCTAssertEqual(fake.values.withLock { $0.scanPriorities }, Array(repeating: .background, count: 6))
        monitor.stop()
    }

    func testAnIdleMachineIsNeverScanned() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()

        for _ in 0..<10 {
            fake.passMinute(busy: 5000, idle: 67_000)
            monitor.tick()
            await monitor.busyScanFinished()
        }

        XCTAssertEqual(fake.reads(.processCPUTimes), 0, "5,000 ticks a minute is under 85 % of a core")
        monitor.stop()
    }

    func testAQuietMinuteDropsTheBusyProcess() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        for _ in 0..<6 { await passLoopMinute(monitor, fake) }
        XCTAssertEqual(monitor.status.cpu, .red)

        fake.passMinute(busy: 100, idle: 71_900)
        monitor.tick()

        XCTAssertEqual(monitor.status.cpu, .green)
        XCTAssertEqual(monitor.status.messages, [])
        monitor.stop()
    }

    func testSleepDropsTheBusyProcess() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        for _ in 0..<6 { await passLoopMinute(monitor, fake) }
        XCTAssertEqual(monitor.status.cpu, .red)

        monitor.sleep()
        monitor.wake()

        XCTAssertEqual(monitor.status.messages, [])
        for _ in 0..<5 { await passLoopMinute(monitor, fake) }
        XCTAssertEqual(monitor.status.messages, [], "a whole window again before it can be red")
        monitor.stop()
    }

    func testWakeAloneDropsTheBusyProcess() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        for _ in 0..<6 { await passLoopMinute(monitor, fake) }
        XCTAssertEqual(monitor.status.cpu, .red)

        monitor.wake()

        XCTAssertEqual(monitor.status.messages, [], "a wake the app wasn't told of a sleep before")
        monitor.stop()
    }

    func testTheGateStaysOpenAtTheClearingShare() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        for _ in 0..<6 { await passLoopMinute(monitor, fake) }
        XCTAssertEqual(monitor.status.cpu, .red)

        fake.passMinute(busy: 5_200, idle: 66_800)
        fake.set { $0.loopCPUTime += 51_600_000_000 }
        monitor.tick()
        await monitor.busyScanFinished()

        XCTAssertEqual(monitor.status.messages, [.busyProcess(name: "loop", percentOfCore: 86, windowMinutes: 5)],
                       "0.87 cores busy is over the 0.85 clearing share, and 86 % is inside the margin")
        monitor.stop()
    }

    func testRaisingTheProcessThresholdClearsTheBusyProcessAtOnce() async {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        for _ in 0..<6 { await passLoopMinute(monitor, fake) }
        XCTAssertEqual(monitor.status.cpu, .red)

        monitor.settings.processCPUPercent = 100

        XCTAssertEqual(monitor.status.cpu, .green)
        XCTAssertEqual(monitor.status.messages, [])
        monitor.stop()
    }
}
