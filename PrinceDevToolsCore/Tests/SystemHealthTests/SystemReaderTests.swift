import Darwin
import Foundation
import System
import XCTest
@testable import SystemHealth

final class SystemReaderTests: XCTestCase {
    func testEffectiveProcessLimit() {
        XCTAssertEqual(effectiveProcessLimit(softLimit: rlim_t(Int64.max), maxProcPerUID: 4000), 4000)
        XCTAssertEqual(effectiveProcessLimit(softLimit: 0, maxProcPerUID: 4000), 4000)
        XCTAssertEqual(effectiveProcessLimit(softLimit: 2000, maxProcPerUID: 4000), 2000)
        XCTAssertEqual(effectiveProcessLimit(softLimit: 10_000, maxProcPerUID: 4000), 4000)
    }

    func testScanSkipsUnreadableProcesses() {
        let usages = processUsages(pids: [10, 11, 12]) { pid in
            switch pid {
            case 10: .failure(.permissionDenied)
            case 11: .failure(.noSuchProcess)
            default: .success(ProcessUsage(pid: pid, name: "p", footprintBytes: 1, cpuTime: 1))
            }
        }
        XCTAssertEqual(usages.map(\.pid), [12])
    }

    func testLiveReadingsArePlausible() async throws {
        XCTAssertNotNil(SystemReader.memoryLevel())
        XCTAssertNotNil(SystemReader.swapUsedBytes())

        let first = try XCTUnwrap(SystemReader.cpuTicks())
        try await Task.sleep(for: .milliseconds(200))
        let second = try XCTUnwrap(SystemReader.cpuTicks())
        let delta = (second.user &- first.user) &+ (second.system &- first.system)
            &+ (second.idle &- first.idle) &+ (second.nice &- first.nice)
        XCTAssertGreaterThan(delta, 0)

        XCTAssertGreaterThan(try XCTUnwrap(SystemReader.diskFreeBytes()), 0)

        let limit = try XCTUnwrap(SystemReader.processLimit())
        let count = try XCTUnwrap(SystemReader.processCount())
        XCTAssertTrue((1...limit).contains(count), "count \(count), limit \(limit)")
    }

    func testLiveScanIncludesThisProcess() throws {
        let name = try XCTUnwrap(Bundle.main.executableURL).resolvingSymlinksInPath().lastPathComponent
        let found = try XCTUnwrap(SystemReader.processUsages().first { $0.pid == getpid() })
        XCTAssertEqual(found.name, name)
        XCTAssertGreaterThan(found.footprintBytes, 0)
    }
}
