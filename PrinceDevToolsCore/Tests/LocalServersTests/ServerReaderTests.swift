import Darwin
import Foundation
import XCTest
@testable import LocalServers

final class ServerReaderTests: XCTestCase {
    func testFindsASocketThisTestListensOn() throws {
        let socket = try listen(family: AF_INET, loopback: true)
        defer { close(socket.fd) }

        let matches = ServerReader.listeningSockets().filter { $0.pid == getpid() && $0.port == socket.port }

        XCTAssertEqual(matches.map(\.address), ["127.0.0.1"])
    }

    func testDualStackListenerReadsAsIPv6Any() throws {
        let socket = try listen(family: AF_INET6, loopback: false)
        defer { close(socket.fd) }

        let matches = ServerReader.listeningSockets().filter { $0.pid == getpid() && $0.port == socket.port }

        XCTAssertEqual(matches.map(\.address), ["::"])
    }

    func testListsNoConnectedSocket() throws {
        let listener = try listen(family: AF_INET, loopback: true)
        defer { close(listener.fd) }
        let client = try connect(toLoopbackPort: listener.port)
        defer { close(client.fd) }
        let accepted = accept(listener.fd, nil, nil)
        defer { close(accepted) }
        XCTAssertGreaterThanOrEqual(accepted, 0)

        let ours = ServerReader.listeningSockets().filter { $0.pid == getpid() }

        XCTAssertEqual(ours.filter { $0.port == listener.port }.count, 1, "the accepted socket shares the port")
        XCTAssertFalse(ours.contains { $0.port == client.port })
    }

    func testReadsThisProcessWithItsFolder() throws {
        let record = try XCTUnwrap(ServerReader.process(of: getpid()))
        let folder = FileManager.default.currentDirectoryPath

        XCTAssertEqual(record.parentPID, getppid())
        XCTAssertLessThan(abs(record.startTime.timeIntervalSinceNow), 3600)
        guard case .path(let path, let identity) = record.folder else { return XCTFail("folder unreadable") }
        XCTAssertEqual(path, folder)
        XCTAssertEqual(ServerReader.checkFolder(folder), .exists(identity))
    }

    func testCheckFolderOfAMissingPathIsMissing() {
        let path = NSTemporaryDirectory() + UUID().uuidString

        XCTAssertEqual(ServerReader.checkFolder(path), .missing)
    }

    func testAnotherUsersProcessReadsAsNil() throws {
        try XCTSkipIf(getuid() == 0, "pid 1 is this user's process when the tests run as root")
        XCTAssertNil(ServerReader.process(of: 1))
    }

    func testPortFloorIsTheKernelsRange() {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let read = sysctlbyname("net.inet.ip.portrange.first", &value, &size, nil, 0) == 0
        let expected = read && (1...65535).contains(value) ? UInt16(value) : 49152

        XCTAssertEqual(ServerReader.portFloor(), expected)
    }

    /// A TCP socket connected to `port` on 127.0.0.1, with its own ephemeral port.
    private func connect(toLoopbackPort port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t($0.pointee.sa_len)) }
        }
        guard connected == 0 else {
            let error = errno
            close(fd)
            throw XCTSkip("could not connect: errno \(error)")
        }
        return (fd, localPort(of: fd))
    }

    private func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        return address
    }

    private func localPort(of fd: Int32) -> UInt16 {
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        return UInt16(bigEndian: name.sin_port)
    }

    /// A listening TCP socket on an ephemeral port; a dual-stack one when `family` is `AF_INET6`.
    private func listen(family: Int32, loopback: Bool) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("could not create a socket: errno \(errno)") }
        let bound: Int32
        if family == AF_INET6 {
            var off: Int32 = 0
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t($0.pointee.sa_len)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = (loopback ? INADDR_LOOPBACK : INADDR_ANY).bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t($0.pointee.sa_len)) }
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let error = errno
            close(fd)
            throw XCTSkip("could not bind and listen: errno \(error)")
        }
        var name = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        let port = withUnsafePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        return (fd, port)
    }
}
