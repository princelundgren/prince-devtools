import XCTest
@testable import SystemHealth

final class HealthEvaluatorTests: XCTestCase {
    private let settings = HealthSettings.defaults

    private func fullCPU(_ percent: Double) -> CPUAverage {
        .full(percent: percent, span: .seconds(300))
    }

    func testUnknownReadingsAreNotKnownAndQuiet() {
        var evaluator = HealthEvaluator()
        let status = evaluator.evaluate(HealthReadings(), settings: settings)
        XCTAssertEqual(status.memory, .notKnown)
        XCTAssertEqual(status.cpu, .notKnown)
        XCTAssertEqual(status.disk, .notKnown)
        XCTAssertEqual(status.processes, .notKnown)
        XCTAssertEqual(status.messages, [])
    }

    func testMemoryLevels() {
        var evaluator = HealthEvaluator()
        var status = evaluator.evaluate(HealthReadings(memory: .normal), settings: settings)
        XCTAssertEqual(status.memory, .green)

        status = evaluator.evaluate(HealthReadings(memory: .warning), settings: settings)
        XCTAssertEqual(status.memory, .yellow)
        XCTAssertEqual(status.messages, [])

        status = evaluator.evaluate(HealthReadings(memory: .critical), settings: settings)
        XCTAssertEqual(status.memory, .red)
        XCTAssertEqual(status.messages, [.memory])

        var strict = settings
        strict.memoryRedLevel = .warning
        status = evaluator.evaluate(HealthReadings(memory: .warning), settings: strict)
        XCTAssertEqual(status.memory, .red)
        XCTAssertEqual(status.messages, [.memory])
    }

    func testCPUPartialIsNeverRed() {
        var evaluator = HealthEvaluator()
        let status = evaluator.evaluate(
            HealthReadings(cpu: .partial(percent: 99, span: .seconds(120))), settings: settings)
        XCTAssertEqual(status.cpu, .green)
        XCTAssertEqual(status.messages, [])
    }

    func testCPUHysteresis() {
        var evaluator = HealthEvaluator()
        let expected: [(Double, CardState)] = [(81, .red), (77, .red), (75, .green), (80, .green)]
        for (percent, state) in expected {
            let status = evaluator.evaluate(HealthReadings(cpu: fullCPU(percent)), settings: settings)
            XCTAssertEqual(status.cpu, state, "at \(percent) %")
        }
    }

    func testCPUMessageCarriesTheWindowSettingNotTheSpan() {
        var evaluator = HealthEvaluator()
        let readings = HealthReadings(cpu: .full(percent: 90, span: .seconds(317)))
        let status = evaluator.evaluate(readings, settings: settings)
        XCTAssertEqual(status.messages, [.cpu(percent: 90, windowMinutes: settings.cpuWindowMinutes)])
    }

    func testDiskHysteresis() {
        var evaluator = HealthEvaluator()
        let expected: [(UInt64, CardState)] = [
            (29_900_000_000, .red), (31_500_000_000, .red), (32_000_000_000, .green), (30_000_000_000, .green)]
        for (free, state) in expected {
            let status = evaluator.evaluate(HealthReadings(diskFreeBytes: free), settings: settings)
            XCTAssertEqual(status.disk, state, "with \(free) bytes free")
        }
    }

    func testProcessHysteresis() {
        var evaluator = HealthEvaluator()
        let expected: [(Int, CardState)] = [(3201, .red), (3050, .red), (3000, .green), (3200, .green)]
        for (count, state) in expected {
            let readings = HealthReadings(processCount: count, processLimit: 4000)
            XCTAssertEqual(evaluator.evaluate(readings, settings: settings).processes, state, "with \(count)")
        }
    }

    func testCPUClearsWhenSamplesDropAfterWake() {
        var evaluator = HealthEvaluator()
        _ = evaluator.evaluate(HealthReadings(cpu: fullCPU(95)), settings: settings)
        var status = evaluator.evaluate(HealthReadings(cpu: .notKnown), settings: settings)
        XCTAssertEqual(status.cpu, .notKnown)
        XCTAssertEqual(status.messages, [])

        status = evaluator.evaluate(HealthReadings(cpu: fullCPU(77)), settings: settings)
        XCTAssertEqual(status.cpu, .green, "the red flag did not survive the gap")
    }

    func testThermal() {
        var evaluator = HealthEvaluator()
        let expected: [(ThermalLevel, ThermalWarning)] = [(.serious, .serious), (.critical, .critical)]
        for (level, warning) in expected {
            let status = evaluator.evaluate(HealthReadings(thermal: level), settings: settings)
            XCTAssertEqual(status.messages, [.thermal(warning)])
            XCTAssertEqual(status.memory, .notKnown)
            XCTAssertEqual(status.cpu, .notKnown)
            XCTAssertEqual(status.disk, .notKnown)
            XCTAssertEqual(status.processes, .notKnown)
        }
        XCTAssertEqual(evaluator.evaluate(HealthReadings(thermal: .normal), settings: settings).messages, [])
    }

    func testThermalLevelMapsProcessInfoStates() {
        XCTAssertEqual(ThermalLevel(.nominal), .normal)
        XCTAssertEqual(ThermalLevel(.fair), .normal)
        XCTAssertEqual(ThermalLevel(.serious), .serious)
        XCTAssertEqual(ThermalLevel(.critical), .critical)
    }

    func testMessageOrder() {
        var evaluator = HealthEvaluator()
        let readings = HealthReadings(
            memory: .critical, cpu: fullCPU(95), diskFreeBytes: 1_000_000_000,
            processCount: 4000, processLimit: 4000, thermal: .critical)
        let status = evaluator.evaluate(readings, settings: settings)
        XCTAssertEqual(status.messages, [
            .memory,
            .disk(freeBytes: 1_000_000_000),
            .processes(count: 4000, limit: 4000),
            .cpu(percent: 95, windowMinutes: 5),
            .thermal(.critical),
        ])
    }

    func testOnlyDiskDoesNotOpenActivityMonitor() {
        XCTAssertFalse(HealthMessage.disk(freeBytes: 1).opensActivityMonitor)
        XCTAssertTrue(HealthMessage.memory.opensActivityMonitor)
        XCTAssertTrue(HealthMessage.processes(count: 1, limit: 2).opensActivityMonitor)
        XCTAssertTrue(HealthMessage.cpu(percent: 1, windowMinutes: 5).opensActivityMonitor)
        XCTAssertTrue(HealthMessage.thermal(.serious).opensActivityMonitor)
    }

    func testMessageClearsWhenCauseEnds() {
        var evaluator = HealthEvaluator()
        XCTAssertEqual(
            evaluator.evaluate(HealthReadings(diskFreeBytes: 20_000_000_000), settings: settings).messages,
            [.disk(freeBytes: 20_000_000_000)])
        XCTAssertEqual(
            evaluator.evaluate(HealthReadings(diskFreeBytes: 40_000_000_000), settings: settings).messages, [])
    }

    func testThresholdChangeAppliesAtOnce() {
        var evaluator = HealthEvaluator()
        let readings = HealthReadings(cpu: fullCPU(70))
        XCTAssertEqual(evaluator.evaluate(readings, settings: settings).cpu, .green)
        var stricter = settings
        stricter.cpuPercent = 60
        XCTAssertEqual(evaluator.evaluate(readings, settings: stricter).cpu, .red)
    }

    func testRedFlagClearsWhenItsMetricReadsNil() {
        var evaluator = HealthEvaluator()
        _ = evaluator.evaluate(HealthReadings(diskFreeBytes: 1_000_000_000), settings: settings)
        _ = evaluator.evaluate(HealthReadings(), settings: settings)
        let status = evaluator.evaluate(HealthReadings(diskFreeBytes: 31_000_000_000), settings: settings)
        XCTAssertEqual(status.disk, .green)
    }
}
