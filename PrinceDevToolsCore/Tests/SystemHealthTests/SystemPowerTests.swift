import XCTest
@testable import SystemHealth

final class SystemPowerTests: XCTestCase {
    func testWillSleepForwardsSleepThenAcknowledges() {
        XCTAssertEqual(SystemPowerResponse(message: 0xE000_0280), .sleepThenAcknowledge)
    }

    func testCanSleepAcknowledgesWithoutVeto() {
        XCTAssertEqual(SystemPowerResponse(message: 0xE000_0270), .acknowledge)
    }

    func testHasPoweredOnForwardsWake() {
        XCTAssertEqual(SystemPowerResponse(message: 0xE000_0300), .wake)
    }

    func testWillPowerOnIsIgnored() {
        XCTAssertEqual(SystemPowerResponse(message: 0xE000_0320), .ignore)
    }

    func testWillNotSleepIsIgnored() {
        XCTAssertEqual(SystemPowerResponse(message: 0xE000_0290), .ignore)
    }

    func testUnknownMessageIsIgnored() {
        XCTAssertEqual(SystemPowerResponse(message: 0xE000_0FFF), .ignore)
        XCTAssertEqual(SystemPowerResponse(message: 0), .ignore)
    }

    func testOnlySleepAndCanSleepAcknowledge() {
        XCTAssertTrue(SystemPowerResponse.sleepThenAcknowledge.acknowledges)
        XCTAssertTrue(SystemPowerResponse.acknowledge.acknowledges)
        XCTAssertFalse(SystemPowerResponse.wake.acknowledges)
        XCTAssertFalse(SystemPowerResponse.ignore.acknowledges)
    }
}
