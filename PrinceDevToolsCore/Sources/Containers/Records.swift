import Foundation

/// A Docker Engine API socket, its path with symlinks resolved, and the runtime's name.
public struct RuntimeSocket: Equatable, Sendable {
    /// For connecting only: it holds folder names from disk as they are, so it is never shown.
    public let path: String
    /// Safe to show: control and bidi characters are replaced.
    public let runtime: String

    public init(path: String, runtime: String) {
        self.path = path
        self.runtime = runtime
    }
}

/// One running container.
public struct Container: Equatable, Sendable, Identifiable {
    public let id: String
    /// The first of the engine's `Names`, without its leading "/".
    public let name: String
    public let image: String
    public let runtime: String
    public let created: Date
    /// `nil` when its stats couldn't be read.
    public let memoryBytes: UInt64?

    public init(
        id: String, name: String, image: String, runtime: String, created: Date, memoryBytes: UInt64?
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.runtime = runtime
        self.created = created
        self.memoryBytes = memoryBytes
    }
}

/// What one pass over the runtimes found.
public struct ContainerScan: Equatable, Sendable {
    /// By memory, largest first, unknown last, then by name.
    public let containers: [Container]
    public let runtimesRead: [String]
    public let unreadableRuntimes: [String]
    public let time: Date

    public init(containers: [Container], runtimesRead: [String], unreadableRuntimes: [String], time: Date) {
        self.containers = containers
        self.runtimesRead = runtimesRead
        self.unreadableRuntimes = unreadableRuntimes
        self.time = time
    }
}
