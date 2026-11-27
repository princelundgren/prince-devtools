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
