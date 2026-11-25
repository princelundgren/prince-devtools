import XCTest
@testable import PanelKit

final class LaunchAtLoginTextTests: XCTestCase {
    func testOffOrOnSaysNoMore() {
        XCTAssertEqual(launchAtLoginSetting(status: .off, failure: nil), LaunchAtLoginSetting(isOn: false, note: nil))
        XCTAssertEqual(launchAtLoginSetting(status: .on, failure: nil), LaunchAtLoginSetting(isOn: true, note: nil))
    }

    func testAwaitingApprovalIsOnAndPointsToLoginItems() {
        XCTAssertEqual(
            launchAtLoginSetting(status: .needsApproval, failure: nil),
            LaunchAtLoginSetting(
                isOn: true, note: .needsApproval("Needs your approval in System Settings → General → Login Items.")))
    }

    func testAFailedTurnOnSaysWhy() {
        let failure = LaunchAtLoginFailure(turningOn: true, reason: "The operation couldn’t be completed.")

        XCTAssertEqual(
            launchAtLoginSetting(status: .notFound, failure: failure),
            LaunchAtLoginSetting(
                isOn: false,
                note: .failed("Couldn't turn on launch at login. The operation couldn’t be completed.")))
    }

    func testAFailedTurnOffSaysWhy() {
        let failure = LaunchAtLoginFailure(turningOn: false, reason: "Operation not permitted.")

        XCTAssertEqual(
            launchAtLoginSetting(status: .on, failure: failure),
            LaunchAtLoginSetting(
                isOn: true, note: .failed("Couldn't turn off launch at login. Operation not permitted.")))
    }

    func testAFailureGoesOnceTheSystemShowsTheChangeHappened() {
        let failedOn = LaunchAtLoginFailure(turningOn: true, reason: "Try again.")
        let failedOff = LaunchAtLoginFailure(turningOn: false, reason: "Try again.")

        XCTAssertNil(launchAtLoginSetting(status: .on, failure: failedOn).note)
        XCTAssertNil(launchAtLoginSetting(status: .off, failure: failedOff).note)
    }

    func testApprovalWinsOverAFailedTurnOn() {
        let failure = LaunchAtLoginFailure(turningOn: true, reason: "Operation not permitted.")

        XCTAssertEqual(
            launchAtLoginSetting(status: .needsApproval, failure: failure).note,
            .needsApproval("Needs your approval in System Settings → General → Login Items."))
    }

    func testTheVersionIsTheMarketingVersionThenTheBuildNumber() {
        XCTAssertEqual(versionText(marketingVersion: "1.0.0", build: "42"), "v1.0.0 (42)")
    }
}
