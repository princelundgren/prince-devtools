import AppKit
import os

/// Apple's Activity Monitor, opened through Launch Services.
enum ActivityMonitor {
    private static let bundleIdentifier = "com.apple.ActivityMonitor"
    private static let logger = Logger(subsystem: "com.princelundgren.princedevtools", category: "ActivityMonitor")

    /// Opens Activity Monitor, or brings it forward if it runs; a failure is only logged.
    @MainActor
    static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            logger.error("No app found for \(bundleIdentifier, privacy: .public)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                logger.error("Opening \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
