import Observation
import Sparkle

/// Sparkle's updater, with a scheduled check's update shown as a row in the panel instead of a
/// window that would appear unasked behind other apps. "Check for Updates…" shows Sparkle's window.
@MainActor
@Observable
final class Updater: NSObject {
    /// The version a scheduled check found, until Sparkle's update session for it ends.
    private(set) var updateVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Shows Sparkle's window: the update found, "no update", or the feed's error. For an update
    /// that waits, it brings that update's window forward.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// A check the user started shows Sparkle's window, so only a scheduled check's update waits.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !state.userInitiated { updateVersion = update.displayVersionString }
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateVersion = nil
    }
}
