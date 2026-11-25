import XCTest
@testable import SystemHealth

final class CulpritTests: XCTestCase {
    private let timebase = MachTimebase(numer: 125, denom: 3)

    private func usage(_ pid: pid_t, _ name: String, footprint: UInt64 = 0, cpu: UInt64 = 0) -> ProcessUsage {
        ProcessUsage(pid: pid, name: name, footprintBytes: footprint, cpuTime: cpu)
    }

    func testMachConversion() {
        XCTAssertEqual(timebase.nanoseconds(3), 125)
        XCTAssertEqual(timebase.nanoseconds(24_000_000), 1_000_000_000)
        let large = UInt64.max / 64
        let expected = UInt64(UInt128(large) * 125 / 3)
        XCTAssertEqual(timebase.nanoseconds(large), expected)
    }

    func testMemoryPicksLargestFootprint() {
        let scan = [usage(1, "a", footprint: 100), usage(2, "b", footprint: 900), usage(3, "c", footprint: 500)]
        XCTAssertEqual(CulpritFinder.memory(scan), .memory(name: "b", bytes: 900))
        XCTAssertNil(CulpritFinder.memory([]))
    }

    func testMemoryTieGoesToAlphabeticallyFirstName() {
        let scan = [usage(1, "zed", footprint: 500), usage(2, "alpha", footprint: 500)]
        XCTAssertEqual(CulpritFinder.memory(scan), .memory(name: "alpha", bytes: 500))
        XCTAssertEqual(CulpritFinder.memory(scan.reversed()), .memory(name: "alpha", bytes: 500))
    }

    func testProcessesPicksMostInstancesByName() {
        let scan = [
            usage(1, "node"), usage(2, "claude"), usage(3, "node"), usage(4, "claude"), usage(5, "node"),
        ]
        XCTAssertEqual(CulpritFinder.processes(scan), .processes(name: "node", count: 3))
        XCTAssertNil(CulpritFinder.processes([]))
    }

    func testCPUPicksLargestDeltaPerCore() {
        let before = [usage(1, "node", cpu: 0), usage(2, "idle", cpu: 0)]
        let after = [usage(1, "node", cpu: 163_200_000), usage(2, "idle", cpu: 24_000_000)]
        let culprit = CulpritFinder.cpu(
            before: before, after: after, interval: .seconds(2), timebase: timebase,
            machineBusyNanoseconds: 8_000_000_000)
        guard case .cpu(let name, let percent) = culprit else {
            return XCTFail("expected a CPU culprit, got \(String(describing: culprit))")
        }
        XCTAssertEqual(name, "node")
        XCTAssertEqual(percent, 340, accuracy: 0.001)
    }

    func testCPUIgnoresPidsMissingFromEitherScanOrGoingBackwards() {
        let before = [usage(1, "steady", cpu: 1_000), usage(2, "reused", cpu: 500_000_000), usage(3, "gone", cpu: 0)]
        let after = [
            usage(1, "steady", cpu: 25_000_000),
            usage(2, "reused", cpu: 10),
            usage(4, "newcomer", cpu: 900_000_000),
        ]
        let culprit = CulpritFinder.cpu(
            before: before, after: after, interval: .seconds(2), timebase: timebase,
            machineBusyNanoseconds: 2_000_000_000)
        guard case .cpu(let name, _) = culprit else {
            return XCTFail("expected a CPU culprit, got \(String(describing: culprit))")
        }
        XCTAssertEqual(name, "steady")
    }

    func testCPUMostlySystem() {
        let before = [usage(1, "node", cpu: 0)]
        let after = [usage(1, "node", cpu: 24_000_000)]
        let culprit = CulpritFinder.cpu(
            before: before, after: after, interval: .seconds(2), timebase: timebase,
            machineBusyNanoseconds: 3_000_000_000)
        XCTAssertEqual(culprit, .mostlySystem)
    }

    func testCPUWithNoDeltaOrZeroIntervalIsNil() {
        let scan = [usage(1, "node", cpu: 100)]
        XCTAssertNil(CulpritFinder.cpu(
            before: scan, after: scan, interval: .seconds(2), timebase: timebase, machineBusyNanoseconds: 0))
        let after = [usage(1, "node", cpu: 24_000_000)]
        XCTAssertNil(CulpritFinder.cpu(
            before: scan, after: after, interval: .zero, timebase: timebase, machineBusyNanoseconds: 1_000_000_000))
    }
}
