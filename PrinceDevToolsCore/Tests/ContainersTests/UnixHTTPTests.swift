import Foundation
import XCTest
@testable import Containers

/// Live: each test makes real Unix sockets in a short folder of its own under /tmp, since
/// `sun_path` holds 104 bytes.
final class UnixHTTPTests: XCTestCase {
    private var folder = ""
    private var descriptors: [Int32] = []

    override func setUpWithError() throws {
        folder = "/tmp/dt-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        descriptors.forEach { close($0) }
        try FileManager.default.removeItem(atPath: folder)
    }

    func testMissingSocketIsNotRunning() async {
        let error = await failure(socket: "\(folder)/s.sock")

        XCTAssertEqual(error, .notRunning)
    }

    func testRefusedConnectionIsNotRunning() async throws {
        let path = try refusingSocket()

        let error = await failure(socket: path)

        XCTAssertEqual(error, .notRunning)
    }

    func testFileThatIsNotASocketIsNotRunning() async throws {
        let file = "\(folder)/s.sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data()))

        let fileError = await failure(socket: file)
        let folderError = await failure(socket: folder)

        XCTAssertEqual(fileError, .notRunning)
        XCTAssertEqual(folderError, .notRunning)
    }

    func testNoListenerFailsFast() async throws {
        let path = try refusingSocket()
        let clock = ContinuousClock()

        let elapsed = await clock.measure { _ = await failure(socket: path, timeout: .seconds(2)) }

        // Timing-dependent: a refused connection fails at once, far inside 1 s; a miss means a wait.
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testReadsFromAListener() async throws {
        let path = "\(folder)/s.sock"
        let listener = try listeningSocket(at: path)
        answerOnce(on: listener, expecting: "GET /version HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")

        let body = try await UnixHTTP.get(socket: path, path: "/version", timeout: .seconds(2), limit: 1_024)

        XCTAssertEqual(body, Data("{}".utf8))
    }

    /// The kernel completes a connection to a listening socket that never accepts, so the request
    /// is sent and no answer comes.
    func testSilentListenerTimesOut() async throws {
        let path = "\(folder)/s.sock"
        _ = try listeningSocket(at: path)

        let error = await failure(socket: path, timeout: .milliseconds(200))

        guard case .failed = error else { return XCTFail("expected .failed, got \(String(describing: error))") }
    }

    func testMalformedRequestTargetIsRefusedBeforeConnecting() async {
        let missing = "\(folder)/s.sock"

        for target in ["", "version", "/v1.47 /info", "/v1.47\r/info", "/v1.47\n/info", "/v1.47/info\r\nGET /"] {
            let error = await failure(socket: missing, path: target)

            guard case .failed = error else {
                return XCTFail("expected .failed for \(target.debugDescription), got \(String(describing: error))")
            }
        }
    }

    func testResponseOverTheRequestsLimitFails() async throws {
        let path = "\(folder)/s.sock"
        let listener = try listeningSocket(at: path)
        answerOnce(on: listener, expecting: "GET /version HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")

        let error = await failure(socket: path, limit: 16)

        guard case .failed = error else { return XCTFail("expected .failed, got \(String(describing: error))") }
    }

    func testEndlessResponseFailsBeforeTheTimeout() async throws {
        let path = "\(folder)/s.sock"
        let listener = try listeningSocket(at: path)
        answerWithoutEnd(on: listener)
        let clock = ContinuousClock()

        var error: SocketReadError?
        let elapsed = await clock.measure { error = await failure(socket: path, timeout: .seconds(5)) }

        guard case .failed = error else { return XCTFail("expected .failed, got \(String(describing: error))") }
        // Timing-dependent: the size limit ends the read long before the 5 s timeout would.
        XCTAssertLessThan(elapsed, .seconds(4))
    }

    private func failure(
        socket: String, path: String = "/version", timeout: Duration = .seconds(2), limit: Int = 16 << 20
    ) async -> SocketReadError? {
        do {
            _ = try await UnixHTTP.get(socket: socket, path: path, timeout: timeout, limit: limit)
            return nil
        } catch {
            return error
        }
    }

    /// A socket file that refuses connections: bound, then closed without listening.
    private func refusingSocket() throws -> String {
        let path = "\(folder)/s.sock"
        close(try boundSocket(at: path))
        return path
    }

    private func listeningSocket(at path: String) throws -> Int32 {
        let descriptor = try boundSocket(at: path)
        descriptors.append(descriptor)
        guard listen(descriptor, 1) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    private func boundSocket(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path), "socket path too long")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        return descriptor
    }

    /// Accepts one connection, reads its request head, and answers 200 with `{}` when it is
    /// `expected`, else 400; then closes.
    private func answerOnce(on listener: Int32, expecting expected: String) {
        Thread.detachNewThread {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while request.firstRange(of: Data("\r\n\r\n".utf8)) == nil {
                let count = read(connection, &buffer, buffer.count)
                guard count > 0 else { return }
                request.append(contentsOf: buffer[..<count])
            }
            let response = request == Data(expected.utf8)
                ? "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
                : "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
            _ = response.withCString { write(connection, $0, strlen($0)) }
        }
    }

    /// Accepts one connection and, without reading it, sends a 200 head and then body bytes until
    /// the client closes.
    private func answerWithoutEnd(on listener: Int32) {
        Thread.detachNewThread {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let head = "HTTP/1.1 200 OK\r\nContent-Length: 1000000000000\r\n\r\n"
            _ = head.withCString { write(connection, $0, strlen($0)) }
            let chunk = [UInt8](repeating: 0x20, count: 65_536)
            while write(connection, chunk, chunk.count) > 0 {}
        }
    }
}
