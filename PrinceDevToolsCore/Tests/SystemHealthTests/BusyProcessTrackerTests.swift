import XCTest
@testable import SystemHealth

/// The tracker fed one scan a minute. With a 1:1 timebase CPU time is nanoseconds, so a process
/// at `p` % of a core gains `p` × 0.6 s of CPU time a minute.
final class BusyProcessTrackerTests: XCTestCase {
    private let window = Duration.seconds(300)
    private let start = ContinuousClock.now
    private var tracker = BusyProcessTracker()
    private var minute = 0
    private var cpuTimes: [pid_t: UInt64] = [:]
    private var names: [pid_t: String] = [:]
    private var namedPIDs: [pid_t] = []

    /// Records a scan one minute after the last, each process having used its share of a core.
    private func passMinute(_ shares: [(pid: pid_t, name: String, percent: Double)], late: Duration = .zero) {
        minute += 1
        var scan: [pid_t: UInt64] = [:]
        for process in shares {
            cpuTimes[process.pid, default: 0] += UInt64(process.percent * 600_000_000)
            scan[process.pid] = cpuTimes[process.pid]
            names[process.pid] = process.name
        }
        tracker.record(scan, at: start + .seconds(60 * minute) + late, timebase: MachTimebase(numer: 1, denom: 1))
    }

    private func baseline(_ processes: [(pid: pid_t, name: String)], late: Duration = .zero) {
        for process in processes { names[process.pid] = process.name }
        tracker.record(
            Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, 0) }), at: start + late,
            timebase: MachTimebase(numer: 1, denom: 1))
    }

    private func busiest(over threshold: Int = 90, window: Duration? = nil) -> BusyProcess? {
        let names = names
        var asked: [pid_t] = []
        defer { namedPIDs = asked }
        return tracker.busiest(over: threshold, window: window ?? self.window) { pid in
            asked.append(pid)
            return names[pid]
        }
    }

    func testRedOnlyOnceAWholeWindowOfMinutesIsOverTheThreshold() {
        baseline([(1, "node")])
        for _ in 0..<4 {
            passMinute([(1, "node", 95)])
            XCTAssertNil(busiest(), "minute \(minute) of 5")
        }
        passMinute([(1, "node", 95)])
        XCTAssertEqual(busiest()?.name, "node")
        XCTAssertEqual(busiest()?.percentOfCore ?? 0, 95, accuracy: 0.001)
    }

    func testTheLongestWindowFitsTheMinutesKept() {
        baseline([(1, "node")])
        for _ in 0..<14 { passMinute([(1, "node", 95)]) }
        XCTAssertNil(busiest(window: .seconds(900)), "14 of 15 minutes")
        passMinute([(1, "node", 95)])
        XCTAssertEqual(busiest(window: .seconds(900))?.name, "node")
        for _ in 0..<5 { passMinute([(1, "node", 95)]) }
        XCTAssertEqual(busiest(window: .seconds(900))?.name, "node", "still red after 20 minutes")
    }

    func testANewWindowIsJudgedAtOnceAgainstTheMinutesKept() {
        baseline([(1, "node")])
        for _ in 0..<5 { passMinute([(1, "node", 95)]) }
        XCTAssertEqual(busiest()?.name, "node")
        XCTAssertNil(busiest(window: .seconds(600)), "10 min needs minutes not scanned yet")
        XCTAssertEqual(busiest(window: .seconds(180))?.name, "node")
    }

    func testCPUTimeIsConvertedFromMachUnits() {
        let timebase = MachTimebase(numer: 125, denom: 3)
        names[1] = "node"
        tracker.record([1: 0], at: start, timebase: timebase)
        for minute in 1...5 {
            let nanoseconds = UInt64(minute) * 57_000_000_000
            tracker.record([1: nanoseconds * 3 / 125], at: start + .seconds(60 * minute), timebase: timebase)
        }
        XCTAssertEqual(busiest(over: 90)?.percentOfCore ?? 0, 95, accuracy: 0.001)
    }

    func testAScanOlderThanTheLastIsIgnored() {
        baseline([(1, "node")])
        passMinute([(1, "node", 95)])
        tracker.record(cpuTimes, at: start + .seconds(30), timebase: MachTimebase(numer: 1, denom: 1))
        for _ in 0..<4 { passMinute([(1, "node", 95)]) }
        XCTAssertEqual(busiest()?.percentOfCore ?? 0, 95, accuracy: 0.001)
    }

    func testTwoScansDelayedPastTheSlackStillFitTheLongestWindow() {
        baseline([(1, "node")], late: .seconds(20))
        passMinute([(1, "node", 95)], late: .seconds(20))
        for _ in 0..<14 { passMinute([(1, "node", 95)]) }
        XCTAssertNil(busiest(window: .seconds(900)), "15 minutes spanning 880 s")
        passMinute([(1, "node", 95)])
        XCTAssertEqual(busiest(window: .seconds(900))?.name, "node", "16 minutes spanning 940 s")
    }

    /// One interval of `seconds` with "node" at 95 % of a core, judged against a 1 minute window.
    private func oneIntervalAgainstAMinute(lasting seconds: Int) -> BusyProcess? {
        baseline([(1, "node")])
        let cpuTime = UInt64(0.95 * Double(seconds) * 1_000_000_000)
        tracker.record([1: cpuTime], at: start + .seconds(seconds), timebase: MachTimebase(numer: 1, denom: 1))
        return busiest(window: .seconds(60))
    }

    func testAnIntervalUpToTheSlackShortOfTheWindowFillsIt() {
        XCTAssertEqual(oneIntervalAgainstAMinute(lasting: 50)?.name, "node")
    }

    func testAnIntervalMoreThanTheSlackShortOfTheWindowDoesNot() {
        XCTAssertNil(oneIntervalAgainstAMinute(lasting: 49))
    }

    func testOnlyARedProcessIsNamed() {
        baseline([(1, "node"), (2, "zsh"), (3, "cargo")])
        for _ in 0..<5 { passMinute([(1, "node", 95), (2, "zsh", 60), (3, "cargo", 0)]) }
        XCTAssertEqual(busiest()?.name, "node")
        XCTAssertEqual(namedPIDs, [1])
    }

    func testARedProcessThatCannotBeNamedIsPassedOver() {
        baseline([(1, "node")])
        for _ in 0..<5 { passMinute([(1, "node", 95)]) }
        names[1] = nil
        XCTAssertNil(busiest())
    }

    func testAQuieterMinuteStartsTheCountOver() {
        baseline([(1, "node")])
        for _ in 0..<4 { passMinute([(1, "node", 95)]) }
        passMinute([(1, "node", 80)])
        for _ in 0..<4 { passMinute([(1, "node", 95)]) }
        XCTAssertNil(busiest(), "only 4 minutes in a row since the quiet one")
        passMinute([(1, "node", 95)])
        XCTAssertEqual(busiest()?.name, "node")
    }

    func testRedClearsOnlyFiveBelowTheThreshold() {
        baseline([(1, "node")])
        for _ in 0..<5 { passMinute([(1, "node", 95)]) }
        XCTAssertNotNil(busiest())
        passMinute([(1, "node", 86)])
        XCTAssertEqual(busiest()?.name, "node", "86 % is inside the 5-point margin")
        passMinute([(1, "node", 85)])
        XCTAssertNil(busiest(), "85 % is at the clearing line")
    }

    func testAReusedPidStartsOver() {
        baseline([(1, "node")])
        for _ in 0..<5 { passMinute([(1, "node", 95)]) }
        XCTAssertNotNil(busiest())
        cpuTimes[1] = 0
        passMinute([(1, "python3", 95)])
        XCTAssertNil(busiest(), "CPU time fell, so pid 1 is a new process")
    }

    func testAnExitedProcessClears() {
        baseline([(1, "node"), (2, "zsh")])
        for _ in 0..<5 { passMinute([(1, "node", 95), (2, "zsh", 0)]) }
        XCTAssertNotNil(busiest())
        passMinute([(2, "zsh", 0)])
        XCTAssertNil(busiest())
    }

    func testTheBusiestRedProcessIsNamedAndTiesGoToTheFirstName() {
        let tied = ["node", "cargo", "swift", "rustc", "go", "bun", "zig", "java"]
        let processes = tied.enumerated().map { (pid: pid_t($0.offset + 2), name: $0.element) }
        baseline([(1, "slow")] + processes)
        for _ in 0..<5 { passMinute([(1, "slow", 120)] + processes.map { ($0.pid, $0.name, 300) }) }
        // The red set's order changes from run to run, so without the tie-break this fails 7 runs in 8.
        XCTAssertEqual(busiest()?.name, "bun")
        XCTAssertEqual(busiest()?.percentOfCore ?? 0, 300, accuracy: 0.001)
    }

    func testANewThresholdIsJudgedAtOnceAgainstTheMinutesKept() {
        baseline([(1, "node")])
        for _ in 0..<5 { passMinute([(1, "node", 150)]) }
        XCTAssertNotNil(busiest(over: 90))
        XCTAssertNil(busiest(over: 200))
        XCTAssertEqual(busiest(over: 100)?.name, "node", "the five kept minutes are all over 100 %")
        XCTAssertNil(busiest(over: 151), "a raised threshold drops the red before its margin applies")
    }

    func testResetForgetsTheBaseline() {
        baseline([(1, "node")])
        for _ in 0..<5 { passMinute([(1, "node", 95)]) }
        tracker.reset()
        XCTAssertNil(busiest())
        for _ in 0..<5 { passMinute([(1, "node", 95)]) }
        XCTAssertNil(busiest(), "the first scan after a reset is only a baseline")
        passMinute([(1, "node", 95)])
        XCTAssertEqual(busiest()?.name, "node")
    }
}
