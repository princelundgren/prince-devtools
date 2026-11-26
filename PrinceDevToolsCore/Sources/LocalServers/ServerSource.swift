import Darwin
import Foundation

/// Where the server list comes from, so tests can supply their own. Every closure is non-blocking
/// and may be called off the main actor.
public struct ServerSource: Sendable {
    /// Every listening TCP socket of the user's processes; a process that fails a read is skipped.
    public var listeningSockets: @Sendable () -> [ListeningSocket]
    /// `nil` once the process has exited or when it isn't the user's.
    public var process: @Sendable (pid_t) -> ProcessRecord?
    /// The last component of the process's executable path, `nil` when it can't be read.
    public var processName: @Sendable (pid_t) -> String?
    public var checkFolder: @Sendable (String) -> FolderCheck
    /// The first port the kernel hands out for a bind to port 0.
    public var portFloor: @Sendable () -> UInt16
    public var homeFolder: String
    public var now: @Sendable () -> Date

    public init(
        listeningSockets: @escaping @Sendable () -> [ListeningSocket],
        process: @escaping @Sendable (pid_t) -> ProcessRecord?,
        processName: @escaping @Sendable (pid_t) -> String?,
        checkFolder: @escaping @Sendable (String) -> FolderCheck,
        portFloor: @escaping @Sendable () -> UInt16,
        homeFolder: String,
        now: @escaping @Sendable () -> Date
    ) {
        self.listeningSockets = listeningSockets
        self.process = process
        self.processName = processName
        self.checkFolder = checkFolder
        self.portFloor = portFloor
        self.homeFolder = homeFolder
        self.now = now
    }
}
