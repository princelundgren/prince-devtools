/// The app's login item as the system reports it.
public enum LaunchAtLoginStatus: Equatable, Sendable {
    case off
    case on
    /// Registered, but waiting for the user to allow it in System Settings → General → Login Items.
    case needsApproval
    /// The system can't find the app's login item.
    case notFound
}

/// Turning launch at login on (`turningOn`) or off failed, for the system's `reason`.
public struct LaunchAtLoginFailure: Equatable, Sendable {
    public let turningOn: Bool
    public let reason: String

    public init(turningOn: Bool, reason: String) {
        self.turningOn = turningOn
        self.reason = reason
    }
}

/// What Settings → General shows under Launch at login.
public enum LaunchAtLoginNote: Equatable, Sendable {
    /// Shown with Open…, which opens System Settings → General → Login Items.
    case needsApproval(String)
    case failed(String)
}

/// Settings → General's Launch at login toggle.
public struct LaunchAtLoginSetting: Equatable, Sendable {
    public let isOn: Bool
    public let note: LaunchAtLoginNote?

    public init(isOn: Bool, note: LaunchAtLoginNote?) {
        self.isOn = isOn
        self.note = note
    }
}

/// The toggle for the system's `status` and the last change that failed, if any. A login item
/// waiting for approval is on, and says where to approve it; a failure shows until the status
/// shows the change happened after all.
public func launchAtLoginSetting(status: LaunchAtLoginStatus, failure: LaunchAtLoginFailure?) -> LaunchAtLoginSetting {
    let isOn = status == .on || status == .needsApproval
    if status == .needsApproval {
        return LaunchAtLoginSetting(
            isOn: isOn, note: .needsApproval("Needs your approval in System Settings → General → Login Items."))
    }
    guard let failure, failure.turningOn != isOn else { return LaunchAtLoginSetting(isOn: isOn, note: nil) }
    let change = failure.turningOn ? "on" : "off"
    return LaunchAtLoginSetting(isOn: isOn, note: .failed("Couldn't turn \(change) launch at login. \(failure.reason)"))
}

/// Settings → About's version: "v1.0.0 (42)", the marketing version and the build number.
public func versionText(marketingVersion: String, build: String) -> String {
    "v\(marketingVersion) (\(build))"
}
