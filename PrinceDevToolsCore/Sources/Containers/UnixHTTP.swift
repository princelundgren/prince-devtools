import Foundation
import Network
import Synchronization

/// Why a read of a Docker Engine API socket gave no body: nothing runs there, or something does
/// and couldn't be read.
public enum SocketReadError: Error, Equatable, Sendable {
    /// Nothing listens: the file is missing, isn't a socket, or refuses the connection.
    case notRunning
    /// A request target that isn't visible ASCII, any other connection error, a status other than
    /// 200, a body the app can't read, a response over the request's limit, or no response within
    /// the timeout. The text says which.
    case failed(String)
}

/// Fetches a path from a socket; replaced in tests.
public struct DockerTransport: Sendable {
    /// Returns the body of `GET path` from the Unix socket at `socket`, or throws why it couldn't;
    /// a response over `limit` bytes fails. Called concurrently, off the main actor.
    public var get: @Sendable (_ socket: String, _ path: String, _ limit: Int) async throws(SocketReadError) -> Data

    /// A transport that answers every request with `get`.
    public init(
        get: @escaping @Sendable (_ socket: String, _ path: String, _ limit: Int) async throws(SocketReadError) -> Data
    ) {
        self.get = get
    }
}

public enum UnixHTTP {
    /// `get` with a 2-second timeout.
    public static let transport = DockerTransport { socket, path, limit throws(SocketReadError) in
        try await get(socket: socket, path: path, timeout: .seconds(2), limit: limit)
    }

    /// Sends `GET path` over the Unix socket at `socket` and returns the body of its 200 response,
    /// read to the connection's close. Throws `.failed`, before connecting, when `path` doesn't
    /// start with `/` or holds anything but visible ASCII (0x21-0x7E), so no peer-supplied text can
    /// end the request line.
    /// Throws `.notRunning` when the socket file is missing, isn't a socket, or refuses the
    /// connection; `.failed` on any other error, a status other than 200, a malformed response, a
    /// response over `limit` bytes, or no complete response within `timeout`.
    public static func get(
        socket: String, path: String, timeout: Duration, limit: Int
    ) async throws(SocketReadError) -> Data {
        guard path.hasPrefix("/"), path.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw .failed("refusing the request target \(path.debugDescription)")
        }
        let request = Data("GET \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n".utf8)
        let response = await Exchange(socket: socket, request: request, limit: limit).run(timeout: timeout)
        return try HTTPResponse.body(of: response.get())
    }
}

/// One request on its own connection. The state, receive and timeout callbacks can race, so
/// `finish` resumes the continuation for whichever comes first and ignores the rest.
private final class Exchange: Sendable {
    /// Every exchange's callbacks run on this one serial queue, one at a time.
    private static let queue = DispatchQueue(label: "UnixHTTP")

    private struct Progress {
        var continuation: CheckedContinuation<Result<Data, SocketReadError>, Never>?
        var timeout: Task<Void, Never>?
        var isReady = false
        var response = Data()
    }

    private let socket: String
    private let request: Data
    private let limit: Int
    private let connection: NWConnection
    private let progress = Mutex(Progress())

    init(socket: String, request: Data, limit: Int) {
        self.socket = socket
        self.request = request
        self.limit = limit
        // A Unix endpoint takes the TCP parameters for a stream; `NWParameters()` has no protocol
        // and fails with ENETDOWN.
        connection = NWConnection(to: .unix(path: socket), using: .tcp)
    }

    func run(timeout: Duration) async -> Result<Data, SocketReadError> {
        await withCheckedContinuation { continuation in
            progress.withLock {
                $0.continuation = continuation
                $0.timeout = Task { [self] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    finish(.failure(.failed("no response from \(socket) within \(timeout)")))
                }
            }
            connection.stateUpdateHandler = { [self] state in handle(state) }
            connection.start(queue: Self.queue)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            progress.withLock { $0.isReady = true }
            connection.send(content: request, completion: .contentProcessed { [self] error in
                if let error { finish(.failure(.failed("sending to \(socket) failed: \(error)"))) }
            })
            receive()
        case .waiting(let error), .failed(let error):
            // Once ready, the peer's close can report `.failed` before the last receive delivers
            // its bytes, so the receive decides.
            guard !progress.withLock({ $0.isReady }) else { return }
            finish(.failure(connectError(error)))
        case .cancelled:
            connection.stateUpdateHandler = nil
        default:
            break
        }
    }

    private func connectError(_ error: NWError) -> SocketReadError {
        if case .posix(let code) = error, [.ENOENT, .ECONNREFUSED, .ENOTSOCK].contains(code) {
            return .notRunning
        }
        return .failed("connecting to \(socket) failed: \(error)")
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            let (complete, isTooLong): (Data?, Bool) = progress.withLock {
                if let data { $0.response.append(data) }
                return (isComplete ? $0.response : nil, $0.response.count > limit)
            }
            if let error {
                finish(.failure(.failed("reading from \(socket) failed: \(error)")))
            } else if isTooLong {
                finish(.failure(.failed("the response from \(socket) is over \(limit) bytes")))
            } else if let complete {
                finish(.success(complete))
            } else {
                receive()
            }
        }
    }

    private func finish(_ result: Result<Data, SocketReadError>) {
        let pending = progress.withLock { state in
            defer { state.continuation = nil }
            return (continuation: state.continuation, timeout: state.timeout)
        }
        guard let continuation = pending.continuation else { return }
        pending.timeout?.cancel()
        connection.cancel()
        continuation.resume(returning: result)
    }
}
