import Darwin
import Foundation
import XCTest
@testable import LocalServers

/// A user's processes, as the test sets them. Every folder reads with one identity, and a folder
/// check finds that identity unless the test says otherwise. A parent that isn't in `records`
/// reads as another user's process.
struct FakeProcesses {
    static let home = "/Users/u"
    static let identity = FileIdentity(inode: 7, device: 1)
    static let epoch = Date(timeIntervalSince1970: 1_000_000)

    var sockets: [ListeningSocket] = []
    var records: [pid_t: ProcessRecord] = [:]
    var names: [pid_t: String] = [:]
    var folderChecks: [String: FolderCheck] = [:]
    var floor: UInt16 = 49152

    mutating func listen(
        pid: pid_t, port: UInt16, handle: UInt64? = nil, address: String = "127.0.0.1",
        folder: String = "/Users/u/app", parent: pid_t = 99, startOffset: TimeInterval = 0
    ) {
        sockets.append(
            ListeningSocket(pid: pid, socketHandle: handle ?? UInt64(pid) << 16 | UInt64(port), port: port,
                            address: address))
        if records[pid] == nil { add(pid: pid, parent: parent, folder: folder, startOffset: startOffset) }
        names[pid] = names[pid] ?? "server\(pid)"
    }

    mutating func add(pid: pid_t, parent: pid_t, folder: String, startOffset: TimeInterval = 0) {
        add(pid: pid, parent: parent, reading: .path(folder, identity: Self.identity), startOffset: startOffset)
    }

    mutating func add(pid: pid_t, parent: pid_t, reading: FolderReading, startOffset: TimeInterval = 0) {
        records[pid] = ProcessRecord(
            pid: pid, parentPID: parent, startTime: Self.epoch + startOffset, folder: reading)
    }

    var source: ServerSource {
        let sockets = sockets, records = records, names = names, folderChecks = folderChecks, floor = floor
        return ServerSource(
            listeningSockets: { sockets },
            process: { records[$0] },
            processName: { names[$0] },
            checkFolder: { folderChecks[$0] ?? .exists(Self.identity) },
            portFloor: { floor },
            homeFolder: Self.home,
            now: { Self.epoch + 3600 })
    }

    var servers: [Server] { ServerList.servers(from: source) }
}

final class ServerListTests: XCTestCase {
    func testPortBelowFloorShows() {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 49151)

        XCTAssertEqual(fake.servers.map(\.port), [49151])
    }

    func testPortAtFloorIsHidden() {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 49152)

        XCTAssertEqual(fake.servers, [])
    }

    func testChangedFloorMovesTheCut() {
        var fake = FakeProcesses()
        fake.floor = 10000
        fake.listen(pid: 10, port: 10000)
        fake.listen(pid: 11, port: 9999)

        XCTAssertEqual(fake.servers.map(\.port), [9999])
    }

    func testFolderOutsideHomeIsHidden() {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 3000, folder: "/")
        fake.listen(pid: 11, port: 3001, folder: "/opt/homebrew")
        fake.listen(pid: 12, port: 3002, folder: "/Users/u/app")

        XCTAssertEqual(fake.servers.map(\.pid), [12])
    }

    func testDeletedFolderUnderHomeShowsAsGone() throws {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 3000, folder: "/Users/u/old")
        fake.folderChecks["/Users/u/old"] = .missing

        let server = try XCTUnwrap(fake.servers.first)
        XCTAssertEqual(fake.servers.count, 1)
        XCTAssertTrue(server.isFolderGone)
        XCTAssertEqual(server.folderPath, "/Users/u/old")
    }

    func testUnreadableFolderShowsAsGone() throws {
        var fake = FakeProcesses()
        fake.add(pid: 10, parent: 99, reading: .unreadable)
        fake.listen(pid: 10, port: 3000)

        let server = try XCTUnwrap(fake.servers.first)
        XCTAssertTrue(server.isFolderGone)
        XCTAssertNil(server.folderPath)
    }

    func testEmptyFolderPathShowsAsGoneWithNoPath() throws {
        var fake = FakeProcesses()
        fake.add(pid: 10, parent: 99, folder: "")
        fake.listen(pid: 10, port: 3000)

        let server = try XCTUnwrap(fake.servers.first)
        XCTAssertTrue(server.isFolderGone)
        XCTAssertNil(server.folderPath)
    }

    func testReplacedFolderShowsAsGone() {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 3000, folder: "/Users/u/app")
        fake.folderChecks["/Users/u/app"] = .exists(FileIdentity(inode: 8, device: 1))

        XCTAssertEqual(fake.servers.map(\.isFolderGone), [true])
    }

    func testUnknownFolderCheckIsNotGone() {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 3000, folder: "/Users/u/app")
        fake.folderChecks["/Users/u/app"] = .unknown

        XCTAssertEqual(fake.servers.map(\.isFolderGone), [false])
    }

    func testIPv4AndIPv6OnOnePortAreOneRow() {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 8000, handle: 1, address: "::1")
        fake.listen(pid: 10, port: 8000, handle: 2, address: "127.0.0.1")

        XCTAssertEqual(fake.servers.map(\.addresses), [["127.0.0.1", "::1"]])
    }

    func testForkedWorkersOnOneSocketAreOneRowShowingTheOldest() {
        var fake = FakeProcesses()
        fake.listen(pid: 20, port: 8000, handle: 5, startOffset: 5)
        fake.listen(pid: 21, port: 8000, handle: 5, startOffset: 0)

        XCTAssertEqual(fake.servers.map(\.pid), [21])
    }

    func testEqualStartTimesShowTheLowestPID() {
        var fake = FakeProcesses()
        fake.listen(pid: 23, port: 8000, handle: 5)
        fake.listen(pid: 22, port: 8000, handle: 5)

        XCTAssertEqual(fake.servers.map(\.pid), [22])
    }

    func testHolderThatExitedMidScanIsSkipped() {
        var fake = FakeProcesses()
        fake.listen(pid: 30, port: 8000, handle: 5, startOffset: 0)
        fake.listen(pid: 31, port: 8000, handle: 5, startOffset: 5)
        fake.listen(pid: 32, port: 9000)
        fake.records[30] = nil
        fake.records[32] = nil

        XCTAssertEqual(fake.servers.map(\.pid), [31])
    }

    func testOneProcessOnTwoPortsIsTwoRows() {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 3000)
        fake.listen(pid: 10, port: 3001)

        XCTAssertEqual(fake.servers.map(\.port), [3000, 3001])
    }

    func testMissingNameKeepsTheRow() {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 3000)
        fake.names[10] = nil

        XCTAssertEqual(fake.servers.map(\.name), [nil])
    }

    func testRowCarriesNameFolderAndStartTime() throws {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 3000, folder: "/Users/u/app", startOffset: 60)

        let server = try XCTUnwrap(fake.servers.first)
        XCTAssertEqual(server.name, "server10")
        XCTAssertEqual(server.folderPath, "/Users/u/app")
        XCTAssertFalse(server.isFolderGone)
        XCTAssertEqual(server.startTime, FakeProcesses.epoch + 60)
    }
}
