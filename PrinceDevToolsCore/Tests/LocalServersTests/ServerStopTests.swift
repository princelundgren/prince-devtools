import Darwin
import Foundation
import XCTest
@testable import LocalServers

final class ServerStopTests: XCTestCase {
    private var sent: [(pid_t, Int32)] = []

    private func stop(_ server: Server, _ signal: StopSignal = .terminate, fake: FakeProcesses, error: Int32 = 0)
        -> StopResult
    {
        ServerStop.stop(server, with: signal, source: fake.source) { pid, number in
            self.sent.append((pid, number))
            return error
        }
    }

    private func listening() throws -> (FakeProcesses, Server) {
        var fake = FakeProcesses()
        fake.listen(pid: 10, port: 3000)
        return (fake, try XCTUnwrap(fake.servers.first))
    }

    func testStopSendsSIGTERMToTheSameProcess() throws {
        let (fake, server) = try listening()

        XCTAssertEqual(stop(server, fake: fake), .sent)
        XCTAssertEqual(sent.map(\.0), [10])
        XCTAssertEqual(sent.map(\.1), [SIGTERM])
    }

    func testForceStopSendsSIGKILL() throws {
        let (fake, server) = try listening()

        XCTAssertEqual(stop(server, .kill, fake: fake), .sent)
        XCTAssertEqual(sent.map(\.1), [SIGKILL])
    }

    func testPIDReusedByAnotherProcessIsNotSignalled() throws {
        var (fake, server) = try listening()
        fake.add(pid: 10, parent: 99, folder: "/Users/u/app", startOffset: 30)

        XCTAssertEqual(stop(server, fake: fake), .processChanged)
        XCTAssertTrue(sent.isEmpty)
    }

    func testExitedProcessIsNotSignalled() throws {
        var (fake, server) = try listening()
        fake.records[10] = nil

        XCTAssertEqual(stop(server, fake: fake), .processChanged)
        XCTAssertTrue(sent.isEmpty)
    }

    func testProcessExitingAsTheSignalIsSentReadsAsChanged() throws {
        let (fake, server) = try listening()

        XCTAssertEqual(stop(server, fake: fake, error: ESRCH), .processChanged)
    }

    func testPIDZeroOrBelowIsNeverSignalled() throws {
        var fake = FakeProcesses()
        for pid: pid_t in [0, -1] {
            fake.add(pid: pid, parent: 1, folder: "/Users/u/app", startOffset: 0)
            let server = Server(
                pid: pid, name: "app", port: 3000, addresses: [], folderPath: nil, isFolderGone: false,
                startTime: try XCTUnwrap(fake.records[pid]).startTime, isParentGone: false)

            XCTAssertEqual(stop(server, fake: fake), .processChanged)
        }
        XCTAssertTrue(sent.isEmpty)
    }

    /// Live: a real child process, read by the real reader, stopped by the real `kill`.
    func testStopEndsARealProcess() throws {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let record = try XCTUnwrap(ServerSource.live.process(child.processIdentifier))
        let server = Server(
            pid: record.pid, name: "sleep", port: 1, addresses: [], folderPath: nil, isFolderGone: false,
            startTime: record.startTime, isParentGone: false)

        XCTAssertEqual(ServerStop.stop(server, with: .terminate, source: .live), .sent)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    func testRefusedSignalReportsItsError() throws {
        let (fake, server) = try listening()

        XCTAssertEqual(stop(server, fake: fake, error: EPERM), .failed(EPERM))
    }
}
