import Foundation

/// Where a scan gets its sockets, its HTTP transport and the clock, so tests can supply their own.
public struct ContainerSource: Sendable {
    public var sockets: @Sendable () -> [RuntimeSocket]
    public var transport: DockerTransport
    public var now: @Sendable () -> Date

    public init(
        sockets: @escaping @Sendable () -> [RuntimeSocket], transport: DockerTransport,
        now: @escaping @Sendable () -> Date
    ) {
        self.sockets = sockets
        self.transport = transport
        self.now = now
    }

    /// The sockets found on this Mac's disk, read over real Unix sockets.
    public static let live = ContainerSource(
        sockets: { DockerSockets.candidates(in: .live) }, transport: UnixHTTP.transport, now: Date.init)
}
