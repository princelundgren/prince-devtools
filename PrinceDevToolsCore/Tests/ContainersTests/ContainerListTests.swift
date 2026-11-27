import Foundation
import XCTest
@testable import Containers

final class ContainerListTests: XCTestCase {
    private let orb = RuntimeSocket(path: "/Users/u/.orbstack/run/docker.sock", runtime: "OrbStack")
    private let podman = RuntimeSocket(path: "/var/folders/ab/T/podman/m-api.sock", runtime: "Podman")
    private let generic = RuntimeSocket(path: "/var/run/docker.sock", runtime: "Docker")
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func scan(_ sockets: [RuntimeSocket], _ engine: FakeEngine) async -> ContainerScan {
        await ContainerList.scan(ContainerSource(sockets: { sockets }, transport: engine.transport, now: { [time] in time }))
    }

    func testOneEngineAtTwoSocketsCountsOnce() async {
        let engine = FakeEngine()
        let list = [FakeEngine.container("a1", name: "web")]
        let stats = ["a1": FakeEngine.stats(usage: 100)]
        engine.engine(orb.path, id: "SAME", containers: list, stats: stats)
        engine.engine(generic.path, id: "SAME", containers: list, stats: stats)

        let result = await scan([orb, generic], engine)

        XCTAssertEqual(result.containers.map(\.runtime), ["OrbStack"])
        XCTAssertEqual(result.runtimesRead, ["OrbStack"])
        XCTAssertEqual(result.unreadableRuntimes, [])
    }

    func testTwoEnginesWithAnEmptyIDBothCount() async {
        let engine = FakeEngine()
        engine.engine(orb.path, id: "", containers: [FakeEngine.container("a1", name: "web")])
        engine.engine(podman.path, id: "", containers: [FakeEngine.container("p1", name: "db")])

        let result = await scan([orb, podman], engine)

        XCTAssertEqual(result.runtimesRead, ["OrbStack", "Podman"])
        XCTAssertEqual(Set(result.containers.map(\.name)), ["web", "db"])
    }

    func testNotRunningIsLeftOut() async {
        let engine = FakeEngine()
        engine.fail(orb.path, "/version", .notRunning)
        engine.engine(podman.path, id: "P", containers: [FakeEngine.container("p1", name: "p")], stats: ["p1": FakeEngine.stats(usage: 1)])

        let result = await scan([orb, podman], engine)

        XCTAssertEqual(result.runtimesRead, ["Podman"])
        XCTAssertEqual(result.unreadableRuntimes, [])
    }

    func testUnreadableIsNamed() async {
        let engine = FakeEngine()
        engine.engine(orb.path, id: "O")
        engine.fail(podman.path, "/version", .failed("500"))

        let result = await scan([orb, podman], engine)

        XCTAssertEqual(result.runtimesRead, ["OrbStack"])
        XCTAssertEqual(result.unreadableRuntimes, ["Podman"])
        XCTAssertEqual(result.time, time)
    }

    func testARuntimeNameIsListedOnceHoweverManyOfItsSocketsFail() async {
        let engine = FakeEngine()
        let other = RuntimeSocket(path: "/Users/u/x.sock", runtime: "Docker")
        engine.fail(generic.path, "/version", .failed("500"))
        engine.fail(other.path, "/version", .failed("500"))

        let result = await scan([generic, other], engine)

        XCTAssertEqual(result.unreadableRuntimes, ["Docker"])
    }

    func testAFailedSocketIsUnreadableEvenWhenAnotherSocketReadItsEngine() async {
        let engine = FakeEngine()
        engine.engine(orb.path, id: "SAME", containers: [FakeEngine.container("a1", name: "web")])
        engine.fail(generic.path, "/version", .failed("500"))

        let result = await scan([orb, generic], engine)

        XCTAssertEqual(result.runtimesRead, ["OrbStack"])
        XCTAssertEqual(result.unreadableRuntimes, ["Docker"])
        XCTAssertEqual(result.containers.map(\.name), ["web"])
    }

    func testSortedByMemoryUnknownLast() async {
        let engine = FakeEngine()
        engine.engine(
            orb.path, id: "O",
            containers: [
                FakeEngine.container("u", name: "unknown"), FakeEngine.container("s", name: "small"),
                FakeEngine.container("b", name: "big"), FakeEngine.container("a", name: "also-small")
            ],
            stats: [
                "s": FakeEngine.stats(usage: 10), "b": FakeEngine.stats(usage: 900), "a": FakeEngine.stats(usage: 10)
            ])

        let result = await scan([orb], engine)

        XCTAssertEqual(result.containers.map(\.name), ["big", "also-small", "small", "unknown"])
    }

    func testContainersOfTwoEnginesAreMerged() async {
        let engine = FakeEngine()
        engine.engine(orb.path, id: "O", containers: [FakeEngine.container("a", name: "a")], stats: ["a": FakeEngine.stats(usage: 1)])
        engine.engine(podman.path, id: "P", containers: [FakeEngine.container("b", name: "b")], stats: ["b": FakeEngine.stats(usage: 2)])

        let result = await scan([orb, podman], engine)

        XCTAssertEqual(result.containers.map(\.runtime), ["Podman", "OrbStack"])
    }
}
