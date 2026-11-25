import Foundation
import Synchronization
import XCTest
@testable import SystemHealth

/// A machine whose readings and clock the test sets.
private final class FakeSystem: Sendable {
    enum Reading: CaseIterable {
        case memoryLevel, swapUsedBytes, cpuTicks, diskFreeBytes, processCount, processLimit, thermalLevel
    }

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

    var source: HealthSource {
        HealthSource(
            memoryLevel: { self.read(.memoryLevel) { $0.memory } },
            swapUsedBytes: { self.read(.swapUsedBytes) { $0.swap } },
            cpuTicks: { self.read(.cpuTicks) { $0.ticks } },
            diskFreeBytes: { self.read(.diskFreeBytes) { $0.disk } },
            processCount: { self.read(.processCount) { $0.count } },
            processLimit: { self.read(.processLimit) { $0.limit } },
            thermalLevel: { self.read(.thermalLevel) { $0.thermal } },
            processUsages: { [] },
            now: { self.values.withLock { $0.now } },
            pause: { _ in },
            timebase: MachTimebase(numer: 1, denom: 1),
            ticksPerSecond: 100)
    }

    private func read<Value>(_ reading: Reading, _ value: (Values) -> Value) -> Value {
        values.withLock {
            $0.reads[reading, default: 0] += 1
            return value($0)
        }
    }
}

@MainActor
final class HealthMonitorTests: XCTestCase {
    private let gigabyte: UInt64 = 1_000_000_000

    /// A monitor on `fake` with its own defaults suite, removed when the test ends.
    private func makeMonitor(_ fake: FakeSystem) -> (HealthMonitor, UserDefaults) {
        let suiteName = "HealthMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return (HealthMonitor(source: fake.source, defaults: defaults), defaults)
    }

    /// Five minutes at 90 % busy after `start()`, which fills the default 5 minute window past 80 %.
    private func driveCPURed(_ monitor: HealthMonitor, _ fake: FakeSystem) {
        for _ in 0..<5 {
            fake.passMinute(busy: 90, idle: 10)
            monitor.tick()
        }
    }

    private func hasMessage(_ monitor: HealthMonitor, _ cause: HealthCause) -> Bool {
        monitor.status.messages.contains { $0.cause == cause }
    }

    func testStartReadsEverythingOnce() {
        let fake = FakeSystem()
        fake.set { $0.thermal = .serious }
        let (monitor, _) = makeMonitor(fake)

        monitor.start()

        XCTAssertEqual(monitor.status.memory, .green)
        XCTAssertEqual(monitor.status.disk, .green)
        XCTAssertEqual(monitor.status.processes, .green)
        XCTAssertEqual(monitor.status.cpu, .notKnown)
        XCTAssertEqual(monitor.readings.thermal, .serious)
        XCTAssertEqual(monitor.status.messages, [.thermal(.serious)])
        for reading in FakeSystem.Reading.allCases {
            XCTAssertEqual(fake.reads(reading), 1, "\(reading)")
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

    func testPanelTickRereadsCountDiskSwapMemoryOnly() {
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
        monitor.stop()
    }

    func testWakeDropsCPUAndRereads() {
        let fake = FakeSystem()
        let (monitor, _) = makeMonitor(fake)
        monitor.start()
        driveCPURed(monitor, fake)
        XCTAssertTrue(hasMessage(monitor, .cpu))

        monitor.sleep()
        fake.set { $0.disk = 50 * self.gigabyte }
        monitor.wake()

        XCTAssertFalse(hasMessage(monitor, .cpu))
        XCTAssertEqual(monitor.readings.cpu, .notKnown)
        XCTAssertEqual(monitor.status.cpu, .notKnown)
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

    func testMemoryEventAndThermalChangeReadOnlyTheirLevel() {
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

        XCTAssertEqual(monitor.status.messages, [.memory, .thermal(.critical)])
        for reading in FakeSystem.Reading.allCases {
            let expected = [.memoryLevel, .thermalLevel].contains(reading) ? 2 : 1
            XCTAssertEqual(fake.reads(reading), expected, "\(reading)")
        }
        monitor.stop()
    }
}
