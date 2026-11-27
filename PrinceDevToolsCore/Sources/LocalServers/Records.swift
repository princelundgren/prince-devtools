import Darwin
import Foundation
import System

/// One TCP socket in the LISTEN state, as one process holds it.
public struct ListeningSocket: Sendable, Equatable {
    public let pid: pid_t
    /// The kernel's handle for the socket (`soi_so`); forked holders share it.
    public let socketHandle: UInt64
    /// In host byte order.
    public let port: UInt16
    /// The local address as `inet_ntop` writes it: "127.0.0.1", "0.0.0.0", "::1", "::".
    public let address: String

    public init(pid: pid_t, socketHandle: UInt64, port: UInt16, address: String) {
        self.pid = pid
        self.socketHandle = socketHandle
        self.port = port
        self.address = address
    }
}

/// A file's identity, to tell a folder from a new one at the same path.
public struct FileIdentity: Sendable, Equatable {
    public let inode: UInt64
    public let device: UInt32

    public init(inode: UInt64, device: UInt32) {
        self.inode = inode
        self.device = device
    }
}

/// A process's working directory as the kernel reports it.
public enum FolderReading: Sendable, Equatable {
    case unreadable
    case path(String, identity: FileIdentity)

    /// Whether the folder is `home` or below it, by whole path components; an unreadable or empty
    /// path counts as in it, since it may be a deleted one.
    public func isInHomeFolder(_ home: String) -> Bool {
        guard case .path(let path, _) = self, !path.isEmpty else { return true }
        return FilePath(path).starts(with: FilePath(home))
    }
}

/// What an `lstat` of a folder's path found.
public enum FolderCheck: Sendable, Equatable {
    case exists(FileIdentity)
    case missing
    /// The check failed for another reason, so the folder may still be there.
    case unknown
}

/// The parts of one process the server list needs.
public struct ProcessRecord: Sendable, Equatable {
    public let pid: pid_t
    public let parentPID: pid_t
    public let startTime: Date
    public let folder: FolderReading

    public init(pid: pid_t, parentPID: pid_t, startTime: Date, folder: FolderReading) {
        self.pid = pid
        self.parentPID = parentPID
        self.startTime = startTime
        self.folder = folder
    }
}

/// One row of the server list.
public struct Server: Sendable, Equatable, Identifiable {
    public let pid: pid_t
    /// `nil` when the executable path can't be read; the row shows the pid.
    public let name: String?
    public let port: UInt16
    /// Sorted, without repeats; two for a merged IPv4 and IPv6 row.
    public let addresses: [String]
    /// The path the kernel reported, `nil` when unreadable.
    public let folderPath: String?
    public let isFolderGone: Bool
    public let startTime: Date
    public let isParentGone: Bool

    public var id: String { "\(pid):\(port)" }

    public init(
        pid: pid_t, name: String?, port: UInt16, addresses: [String], folderPath: String?, isFolderGone: Bool,
        startTime: Date, isParentGone: Bool
    ) {
        self.pid = pid
        self.name = name
        self.port = port
        self.addresses = addresses
        self.folderPath = folderPath
        self.isFolderGone = isFolderGone
        self.startTime = startTime
        self.isParentGone = isParentGone
    }
}
