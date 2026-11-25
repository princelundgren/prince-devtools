import XCTest
@testable import SystemHealth

final class HealthSettingsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testEmptyDefaultsGiveTheDesignDefaults() {
        withDefaults { defaults in
            let settings = HealthSettings(reading: defaults)
            XCTAssertEqual(settings.memoryRedLevel, .critical)
            XCTAssertEqual(settings.cpuPercent, 80)
            XCTAssertEqual(settings.cpuWindowMinutes, 5)
            XCTAssertEqual(settings.diskFreeGB, 30)
            XCTAssertEqual(settings.processSharePercent, 80)
            XCTAssertEqual(settings, HealthSettings.defaults)
            XCTAssertEqual(settings.cpuWindow, .seconds(300))
        }
    }

    func testValuesAreClamped() {
        let cases: [(key: String, stored: Int, read: KeyPath<HealthSettings, Int>, expected: Int)] = [
            ("systemHealth.cpuPercent", 10, \.cpuPercent, 50),
            ("systemHealth.cpuPercent", 101, \.cpuPercent, 100),
            ("systemHealth.cpuWindowMinutes", 99, \.cpuWindowMinutes, 15),
            ("systemHealth.cpuWindowMinutes", 1, \.cpuWindowMinutes, 3),
            ("systemHealth.cpuWindowMinutes", -3, \.cpuWindowMinutes, 3),
            ("systemHealth.diskFreeGB", 1, \.diskFreeGB, 5),
            ("systemHealth.diskFreeGB", 9999, \.diskFreeGB, 500),
            ("systemHealth.processSharePercent", 20, \.processSharePercent, 50),
            ("systemHealth.processSharePercent", 99, \.processSharePercent, 95),
        ]
        for testCase in cases {
            withDefaults { defaults in
                defaults.set(testCase.stored, forKey: testCase.key)
                XCTAssertEqual(HealthSettings(reading: defaults)[keyPath: testCase.read], testCase.expected,
                               "\(testCase.key) stored as \(testCase.stored)")
            }
        }
    }

    func testWrongTypesFallBackToDefaults() {
        withDefaults { defaults in
            defaults.set("eighty", forKey: "systemHealth.cpuPercent")
            defaults.set("warning", forKey: "systemHealth.memoryRedLevel")
            XCTAssertEqual(HealthSettings(reading: defaults).cpuPercent, 80)
            XCTAssertEqual(HealthSettings(reading: defaults).memoryRedLevel, .critical)
        }
        withDefaults { defaults in
            defaults.set(MemoryLevel.normal.rawValue, forKey: "systemHealth.memoryRedLevel")
            XCTAssertEqual(HealthSettings(reading: defaults).memoryRedLevel, .critical, "normal is not offered")
        }
        withDefaults { defaults in
            // A stored Bool bridges to the Int 1 (true), which is then clamped to the range minimum.
            defaults.set(true, forKey: "systemHealth.cpuPercent")
            XCTAssertEqual(HealthSettings(reading: defaults).cpuPercent, 50)
        }
    }

    func testMemoryRedLevelAcceptsWarningAndCritical() {
        for level in [MemoryLevel.warning, .critical] {
            withDefaults { defaults in
                defaults.set(level.rawValue, forKey: "systemHealth.memoryRedLevel")
                XCTAssertEqual(HealthSettings(reading: defaults).memoryRedLevel, level)
            }
        }
    }

    func testSaveRoundTrips() {
        withDefaults { defaults in
            let saved = HealthSettings(memoryRedLevel: .warning, cpuPercent: 90, cpuWindowMinutes: 10,
                                       diskFreeGB: 50, processSharePercent: 70)
            saved.save(to: defaults)
            XCTAssertEqual(HealthSettings(reading: defaults), saved)
            XCTAssertEqual(defaults.object(forKey: "systemHealth.memoryRedLevel") as? Int, 2)
        }
    }
}
