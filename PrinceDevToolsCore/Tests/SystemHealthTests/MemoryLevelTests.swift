import XCTest
@testable import SystemHealth

final class MemoryLevelTests: XCTestCase {
    func testSysctlValues() {
        XCTAssertEqual(MemoryLevel(sysctlValue: 1), .normal)
        XCTAssertEqual(MemoryLevel(sysctlValue: 2), .warning)
        XCTAssertEqual(MemoryLevel(sysctlValue: 4), .critical)
        for unknown: Int32 in [0, 3, 8, -1] {
            XCTAssertNil(MemoryLevel(sysctlValue: unknown), "sysctl value \(unknown)")
        }
    }

    func testLevelsOrderByPressure() {
        XCTAssertLessThan(MemoryLevel.normal, .warning)
        XCTAssertLessThan(MemoryLevel.warning, .critical)
        XCTAssertEqual(MemoryLevel.allCases.sorted(), [.normal, .warning, .critical])
    }
}
