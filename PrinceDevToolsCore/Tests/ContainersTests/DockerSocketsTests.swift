import Foundation
import XCTest
@testable import Containers

/// A disk the test sets: the socket files that exist (each with the path its symlinks resolve to),
/// the files with contents, and the folders with entries.
/// Every path, socket or folder, belongs to `user` unless `owners` names another uid for it.
struct FakeDisk {
    static let home = "/Users/u"
    static let temporary = "/var/folders/ab/T/"
    static let user: uid_t = 501

    var sockets: [String: String] = [:]
    var files: [String: Data] = [:]
    var folders: [String: [String]] = [:]
    var owners: [String: uid_t] = [:]

    mutating func socket(_ path: String, resolvingTo target: String? = nil) {
        sockets[path] = target ?? path
    }

    mutating func context(_ name: String, host: String) {
        files["\(Self.home)/.docker/config.json"] = Data(#"{"currentContext":"\#(name)"}"#.utf8)
        let digest = name.hashDigestHex
        files["\(Self.home)/.docker/contexts/meta/\(digest)/meta.json"] = Data(
            #"{"Name":"\#(name)","Endpoints":{"docker":{"Host":"\#(host)"}}}"#.utf8)
    }

    var socketFiles: SocketFiles {
        let sockets = sockets, files = files, folders = folders, owners = owners
        return SocketFiles(
            homeFolder: Self.home,
            temporaryFolder: Self.temporary,
            contents: { files[$0] },
            directoryEntries: { folders[$0] ?? [] },
            resolvedPath: { sockets[$0] },
            userID: Self.user,
            ownerID: { owners[$0] ?? Self.user })
    }

    var candidates: [RuntimeSocket] { DockerSockets.candidates(in: socketFiles) }
}

extension String {
    var hashDigestHex: String { DockerSockets.contextFolderName(self) }
}

final class DockerSocketsTests: XCTestCase {
    func testKnownSocketsInOrder() {
        var disk = FakeDisk()
        disk.socket("/Users/u/.rd/docker.sock")
        disk.socket("/Users/u/.docker/run/docker.sock")
        disk.socket("/Users/u/.orbstack/run/docker.sock")

        XCTAssertEqual(
            disk.candidates,
            [
                RuntimeSocket(path: "/Users/u/.orbstack/run/docker.sock", runtime: "OrbStack"),
                RuntimeSocket(path: "/Users/u/.docker/run/docker.sock", runtime: "Docker Desktop"),
                RuntimeSocket(path: "/Users/u/.rd/docker.sock", runtime: "Rancher Desktop")
            ])
    }

    func testMissingSocketsAreLeftOut() {
        var disk = FakeDisk()
        disk.socket("/Users/u/.docker/run/docker.sock")

        XCTAssertEqual(disk.candidates.map(\.runtime), ["Docker Desktop"])
    }

    func testColimaProfilesAndPodmanMachines() {
        var disk = FakeDisk()
        disk.folders["/Users/u/.colima"] = ["work", "default", "_lima"]
        disk.socket("/Users/u/.colima/default/docker.sock")
        disk.socket("/Users/u/.colima/work/docker.sock")
        disk.folders["/var/folders/ab/T/podman"] = [
            "dev-api.sock", "podman-machine-default-api.sock", "podman-machine-default-gvproxy.sock",
            "podman.log"
        ]
        disk.socket("/var/folders/ab/T/podman/podman-machine-default-api.sock")
        disk.socket("/var/folders/ab/T/podman/podman-machine-default-gvproxy.sock")
        disk.socket("/var/folders/ab/T/podman/dev-api.sock")

        XCTAssertEqual(
            disk.candidates.map(\.runtime), ["Colima", "Colima (work)", "Podman", "Podman (dev)"])
    }

    func testSymlinkToAKnownSocketIsListedOnce() {
        var disk = FakeDisk()
        disk.socket("/Users/u/.orbstack/run/docker.sock")
        disk.socket("/var/run/docker.sock", resolvingTo: "/Users/u/.orbstack/run/docker.sock")

        XCTAssertEqual(
            disk.candidates,
            [RuntimeSocket(path: "/Users/u/.orbstack/run/docker.sock", runtime: "OrbStack")])
    }

    func testVarRunSocketIsNamedDocker() {
        var disk = FakeDisk()
        disk.socket("/var/run/docker.sock")

        XCTAssertEqual(
            disk.candidates, [RuntimeSocket(path: "/var/run/docker.sock", runtime: "Docker")])
    }

    func testActiveContextSocket() {
        var disk = FakeDisk()
        disk.socket("/Users/u/.orbstack/run/docker.sock")
        disk.context("lima-x", host: "unix:///Users/u/x.sock")
        disk.socket("/Users/u/x.sock")

        XCTAssertEqual(
            disk.candidates,
            [
                RuntimeSocket(path: "/Users/u/.orbstack/run/docker.sock", runtime: "OrbStack"),
                RuntimeSocket(path: "/Users/u/x.sock", runtime: "lima-x")
            ])
    }

    func testContextAtAListedSocketIsReadOnceUnderTheListedName() {
        var disk = FakeDisk()
        disk.socket("/Users/u/.orbstack/run/docker.sock")
        disk.context("orbstack", host: "unix:///Users/u/.orbstack/run/docker.sock")

        XCTAssertEqual(
            disk.candidates,
            [RuntimeSocket(path: "/Users/u/.orbstack/run/docker.sock", runtime: "OrbStack")])
    }

    func testContextWithoutAnAbsoluteSocketPathIsSkipped() {
        var disk = FakeDisk()
        disk.socket("")
        disk.socket("x.sock")

        disk.context("empty", host: "unix://")
        XCTAssertEqual(disk.candidates, [])

        disk.context("relative", host: "unix://x.sock")
        XCTAssertEqual(disk.candidates, [])
    }

    func testALinkToAnotherAccountsSocketIsLeftOut() {
        var disk = FakeDisk()
        disk.socket("/var/run/docker.sock", resolvingTo: "/Users/v/.orbstack/run/docker.sock")
        disk.owners["/Users/v/.orbstack/run/docker.sock"] = 502

        XCTAssertEqual(disk.candidates, [])
    }

    func testTheUsersSocketInAnotherAccountsFolderIsLeftOut() {
        var disk = FakeDisk()
        disk.socket("/var/run/docker.sock", resolvingTo: "/Users/v/run/docker.sock")
        disk.owners["/Users/v/run"] = 502

        XCTAssertEqual(disk.candidates, [])
    }

    func testALinkToTheUsersOwnSocketIsKept() {
        var disk = FakeDisk()
        disk.socket("/var/run/docker.sock", resolvingTo: "/Users/u/.orbstack/run/docker.sock")

        XCTAssertEqual(
            disk.candidates, [RuntimeSocket(path: "/Users/u/.orbstack/run/docker.sock", runtime: "Docker")])
    }

    func testAContextSocketOwnedByAnotherAccountIsLeftOut() {
        var disk = FakeDisk()
        disk.context("shared", host: "unix:///Users/v/x.sock")
        disk.socket("/Users/v/x.sock")
        disk.owners["/Users/v/x.sock"] = 502

        XCTAssertEqual(disk.candidates, [])
    }

    func testRuntimeNamesFromDiskAreSanitized() {
        var disk = FakeDisk()
        disk.folders["/Users/u/.colima"] = ["a\nb"]
        disk.socket("/Users/u/.colima/a\nb/docker.sock")
        disk.folders["/var/folders/ab/T/podman"] = ["m\u{202E}-api.sock"]
        disk.socket("/var/folders/ab/T/podman/m\u{202E}-api.sock")
        let longName = "ctx\u{202E}" + String(repeating: "x", count: 2_000)
        disk.context(longName, host: "unix:///Users/u/x.sock")
        disk.socket("/Users/u/x.sock")

        let runtimes = disk.candidates.map(\.runtime)

        XCTAssertEqual(runtimes.prefix(2), ["Colima (a\u{FFFD}b)", "Podman (m\u{FFFD})"])
        XCTAssertTrue(runtimes[2].hasPrefix("ctx\u{FFFD}xxx"), runtimes[2])
        XCTAssertEqual(runtimes[2].utf8.count, 1_024)
    }

    func testALongProfileNameKeepsItsLabelsClosingParenthesis() {
        var disk = FakeDisk()
        let profile = String(repeating: "p", count: 2_000)
        disk.folders["/Users/u/.colima"] = [profile]
        disk.socket("/Users/u/.colima/\(profile)/docker.sock")

        XCTAssertEqual(disk.candidates.map(\.runtime), ["Colima (\(String(repeating: "p", count: 1_024)))"])
    }

    func testTCPContextIsSkipped() {
        var disk = FakeDisk()
        disk.context("remote", host: "tcp://127.0.0.1:2375")

        XCTAssertEqual(disk.candidates, [])
    }

    func testUnreadableConfigMeansNoContext() {
        var disk = FakeDisk()
        disk.socket("/Users/u/.rd/docker.sock")
        disk.files["/Users/u/.docker/config.json"] = Data("not json".utf8)
        XCTAssertEqual(disk.candidates.map(\.runtime), ["Rancher Desktop"])

        disk.files["/Users/u/.docker/config.json"] = nil
        XCTAssertEqual(disk.candidates.map(\.runtime), ["Rancher Desktop"])
    }

    func testContextFolderNameIsTheLowercaseSHA256OfTheName() {
        XCTAssertEqual(
            DockerSockets.contextFolderName("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testLiveFilesResolveALinkAndReadTheOwner() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let target = "\(folder)/docker.sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data()))
        try FileManager.default.createSymbolicLink(atPath: "\(folder)/link.sock", withDestinationPath: target)
        let files = SocketFiles.live

        let resolved = try XCTUnwrap(files.resolvedPath("\(folder)/link.sock"))

        XCTAssertEqual(resolved, URL(fileURLWithPath: target).resolvingSymlinksInPath().path)
        XCTAssertNil(files.resolvedPath("\(folder)/missing.sock"))
        XCTAssertEqual(files.ownerID(resolved), getuid())
        XCTAssertEqual(files.ownerID(folder), getuid())
        XCTAssertNil(files.ownerID("\(folder)/missing.sock"))
        XCTAssertEqual(files.userID, getuid())
    }
}
