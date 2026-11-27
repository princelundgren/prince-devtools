import Foundation
import XCTest
@testable import Containers

/// A transport that answers from a table of (socket, path) to a body or an error, and records
/// the paths asked for. A path missing from the table fails like an engine's 404, and a body over
/// the request's limit fails as `UnixHTTP` does.
final class FakeEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<Data, SocketReadError>] = [:]
    private var asked: [String] = []

    func answer(_ socket: String, _ path: String, _ body: String) {
        set(socket, path, .success(Data(body.utf8)))
    }

    func fail(_ socket: String, _ path: String, _ error: SocketReadError) {
        set(socket, path, .failure(error))
    }

    var paths: [String] { lock.withLock { asked } }

    var transport: DockerTransport {
        DockerTransport { [self] socket, path, limit throws(SocketReadError) in
            let result = lock.withLock { () -> Result<Data, SocketReadError> in
                asked.append(path)
                return answers["\(socket) \(path)"] ?? .failure(.failed("404 for \(path)"))
            }
            let body = try result.get()
            guard body.count <= limit else { throw .failed("\(path) is over \(limit) bytes") }
            return body
        }
    }

    private func set(_ socket: String, _ path: String, _ result: Result<Data, SocketReadError>) {
        lock.withLock { answers["\(socket) \(path)"] = result }
    }

    /// An engine at `socket` with the given version and engine ID, listing `containers`
    /// (JSON objects) and answering each id in `stats` with its stats body.
    func engine(
        _ socket: String, version: String = "1.47", id: String = "ENGINE", containers: [String] = [],
        stats: [String: String] = [:]
    ) {
        answer(socket, "/version", #"{"ApiVersion":"\#(version)"}"#)
        answer(socket, "/v\(version)/info", #"{"ID":"\#(id)"}"#)
        answer(socket, "/v\(version)/containers/json", "[\(containers.joined(separator: ","))]")
        for (container, body) in stats {
            answer(socket, "/v\(version)/containers/\(container)/stats?stream=false&one-shot=true", body)
        }
    }

    static func container(_ id: String, name: String, image: String = "img", created: Int = 1_700_000_000) -> String {
        #"{"Id":"\#(id)","Names":["/\#(name)"],"Image":"\#(image)","Created":\#(created),"State":"running"}"#
    }

    static func stats(usage: UInt64?, inactiveFile: UInt64? = nil) -> String {
        #"{"memory_stats":\#(memoryStats(usage: usage, inactiveFile: inactiveFile))}"#
    }

    static func memoryStats(
        usage: UInt64?, inactiveFile: UInt64? = nil, totalInactiveFile: UInt64? = nil
    ) -> String {
        var memory: [String] = []
        if let usage { memory.append(#""usage":\#(usage)"#) }
        var detail: [String] = []
        if let inactiveFile { detail.append(#""inactive_file":\#(inactiveFile)"#) }
        if let totalInactiveFile { detail.append(#""total_inactive_file":\#(totalInactiveFile)"#) }
        if !detail.isEmpty { memory.append(#""stats":{\#(detail.joined(separator: ","))}"#) }
        return "{\(memory.joined(separator: ","))}"
    }
}

/// Wraps a transport and counts its stats requests in flight, holding each for 200 ms so that
/// requests started together overlap even on a loaded machine.
final class StatsInFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var highest = 0

    var most: Int { lock.withLock { highest } }

    func counting(_ inner: DockerTransport) -> DockerTransport {
        DockerTransport { [self] socket, path, limit throws(SocketReadError) in
            guard path.contains("/stats?") else { return try await inner.get(socket, path, limit) }
            lock.withLock {
                current += 1
                highest = max(highest, current)
            }
            defer { lock.withLock { current -= 1 } }
            try? await Task.sleep(for: .milliseconds(200))
            return try await inner.get(socket, path, limit)
        }
    }
}

final class DockerReaderTests: XCTestCase {
    private let socket = RuntimeSocket(path: "/Users/u/.orbstack/run/docker.sock", runtime: "OrbStack")

    private func read(_ engine: FakeEngine) async -> RuntimeRead {
        await DockerReader.read(socket, transport: engine.transport)
    }

    func testReadsContainersWithMemory() async {
        let engine = FakeEngine()
        engine.engine(
            socket.path, id: "E1",
            containers: [
                FakeEngine.container("a1", name: "web", image: "nginx:1", created: 1_700_000_000),
                FakeEngine.container("b2", name: "db", image: "postgres:16", created: 1_700_000_100)
            ],
            stats: [
                "a1": FakeEngine.stats(usage: 10_000, inactiveFile: 4_000),
                "b2": FakeEngine.stats(usage: 50_000, inactiveFile: 0)
            ])

        let result = await read(engine)

        XCTAssertEqual(result, .read(engineID: "E1", containers: [
            Container(
                id: "a1", name: "web", image: "nginx:1", runtime: "OrbStack",
                created: Date(timeIntervalSince1970: 1_700_000_000), memoryBytes: 6_000),
            Container(
                id: "b2", name: "db", image: "postgres:16", runtime: "OrbStack",
                created: Date(timeIntervalSince1970: 1_700_000_100), memoryBytes: 50_000)
        ]))
    }

    func testRequestsUseTheEnginesVersion() async {
        let engine = FakeEngine()
        engine.engine(
            socket.path, version: "1.47", containers: [FakeEngine.container("a1", name: "web")],
            stats: ["a1": FakeEngine.stats(usage: 1)])

        _ = await read(engine)

        let paths = engine.paths
        XCTAssertEqual(paths.first, "/version")
        XCTAssertTrue(paths.dropFirst().allSatisfy { $0.hasPrefix("/v1.47/") }, "\(paths)")
        XCTAssertEqual(paths.last, "/v1.47/containers/a1/stats?stream=false&one-shot=true")
    }

    func testMemoryOnCgroupsV2() {
        XCTAssertEqual(DockerReader.memoryInUse(stats(usage: 10_000, inactiveFile: 4_000)), 6_000)
    }

    func testMemoryOnCgroupsV1UsesTheTotal() {
        XCTAssertEqual(
            DockerReader.memoryInUse(stats(usage: 10_000, inactiveFile: 500, totalInactiveFile: 1_000)), 9_000)
    }

    func testCacheAtOrAboveUsageIsNotSubtracted() {
        XCTAssertEqual(DockerReader.memoryInUse(stats(usage: 1_000, inactiveFile: 4_000)), 1_000)
    }

    func testV1TotalAboveUsageFallsBackToInactiveFile() {
        XCTAssertEqual(
            DockerReader.memoryInUse(stats(usage: 1_000, inactiveFile: 300, totalInactiveFile: 4_000)), 700)
    }

    func testNoUsageMeansUnknown() {
        XCTAssertNil(DockerReader.memoryInUse(stats(usage: nil, inactiveFile: 4_000)))
    }

    func testUsageAloneIsTheMemory() {
        XCTAssertEqual(DockerReader.memoryInUse(stats(usage: 7_000)), 7_000)
    }

    func testMemoryAboveInt64MaxIsUnknown() {
        XCTAssertEqual(
            DockerReader.memoryInUse(stats(usage: UInt64(Int64.max))), UInt64(Int64.max))
        XCTAssertNil(DockerReader.memoryInUse(stats(usage: UInt64(Int64.max) + 1)))
        XCTAssertNil(DockerReader.memoryInUse(stats(usage: .max)))
    }

    func testAtMostSixteenStatsRequestsAreInFlight() async {
        let engine = FakeEngine()
        let ids = (1...40).map { "c\($0)" }
        engine.engine(
            socket.path, containers: ids.map { FakeEngine.container($0, name: $0) },
            stats: Dictionary(uniqueKeysWithValues: ids.map { ($0, FakeEngine.stats(usage: 1_000)) }))
        let counter = StatsInFlight()

        let result = await DockerReader.read(socket, transport: counter.counting(engine.transport))

        guard case .read(_, let containers) = result else { return XCTFail("expected a read, got \(result)") }
        XCTAssertEqual(containers.count, 40)
        XCTAssertTrue(containers.allSatisfy { $0.memoryBytes == 1_000 })
        XCTAssertEqual(counter.most, 16)
    }

    func testStatsWithoutUsageLeavesMemoryUnknown() async {
        let engine = FakeEngine()
        engine.engine(
            socket.path, containers: [FakeEngine.container("a1", name: "web")],
            stats: ["a1": #"{"memory_stats":{}}"#])

        guard case .read(_, let containers) = await read(engine) else { return XCTFail("not read") }

        XCTAssertEqual(containers.map(\.memoryBytes), [nil])
    }

    func testStatsFailureLeavesMemoryUnknown() async {
        let engine = FakeEngine()
        engine.engine(
            socket.path,
            containers: [FakeEngine.container("a1", name: "web"), FakeEngine.container("b2", name: "gone")],
            stats: ["a1": FakeEngine.stats(usage: 9_000)])

        guard case .read(_, let containers) = await read(engine) else { return XCTFail("not read") }

        XCTAssertEqual(containers.map(\.name), ["web", "gone"])
        XCTAssertEqual(containers.map(\.memoryBytes), [9_000, nil])
    }

    func testNullOrMissingNamesFallBackToTheID() async {
        let engine = FakeEngine()
        engine.engine(
            socket.path,
            containers: [
                #"{"Id":"0123456789abcdef","Names":null,"Image":"i","Created":1}"#,
                #"{"Id":"fedcba9876543210","Image":"i","Created":1}"#
            ])

        guard case .read(_, let containers) = await read(engine) else { return XCTFail("not read") }

        XCTAssertEqual(containers.map(\.name), ["0123456789ab", "fedcba987654"])
    }

    func testRefusedFirstRequestIsNotRunning() async {
        let engine = FakeEngine()
        engine.fail(socket.path, "/version", .notRunning)

        let result = await read(engine)

        XCTAssertEqual(result, .notRunning)
    }

    func testFailedListIsUnreadable() async {
        let engine = FakeEngine()
        engine.engine(socket.path)
        engine.fail(socket.path, "/v1.47/containers/json", .failed("500"))

        let result = await read(engine)

        XCTAssertEqual(result, .unreadable)
    }

    func testFailedVersionIsUnreadable() async {
        let engine = FakeEngine()
        engine.fail(socket.path, "/version", .failed("timeout"))

        let result = await read(engine)

        XCTAssertEqual(result, .unreadable)
    }

    func testBadJSONIsUnreadable() async {
        let engine = FakeEngine()
        engine.engine(socket.path)
        engine.answer(socket.path, "/v1.47/containers/json", "not json")

        let result = await read(engine)

        XCTAssertEqual(result, .unreadable)
    }

    func testAVersionThatIsNotNumbersIsUnreadableAndGoesNoFurther() async {
        let engine = FakeEngine()
        engine.answer(socket.path, "/version", #"{"ApiVersion":"1.47 HTTP/1.1\r\nHost: x\r\n\r\nGET /"}"#)

        let result = await read(engine)

        XCTAssertEqual(result, .unreadable)
        XCTAssertEqual(engine.paths, ["/version"])
    }

    func testAnIDThatIsNotPlainGetsNoStatsRequest() async {
        let engine = FakeEngine()
        engine.engine(
            socket.path,
            containers: [
                FakeEngine.container("a1", name: "web"),
                FakeEngine.container("../info", name: "slashed"),
                FakeEngine.container("b2?x", name: "queried"),
                FakeEngine.container("..", name: "dots")
            ],
            stats: ["a1": FakeEngine.stats(usage: 1_000)])

        guard case .read(_, let containers) = await read(engine) else { return XCTFail("not read") }

        XCTAssertEqual(containers.map(\.memoryBytes), [1_000, nil, nil, nil])
        XCTAssertEqual(
            engine.paths.filter { $0.contains("/stats?") }, ["/v1.47/containers/a1/stats?stream=false&one-shot=true"])
    }

    func testStatsOver64KiBLeaveMemoryUnknown() async {
        let engine = FakeEngine()
        let padded = FakeEngine.stats(usage: 1_000) + String(repeating: " ", count: 64 << 10)
        engine.engine(socket.path, containers: [FakeEngine.container("a1", name: "web")], stats: ["a1": padded])

        guard case .read(_, let containers) = await read(engine) else { return XCTFail("not read") }

        XCTAssertEqual(containers.map(\.memoryBytes), [nil])
    }

    func testARealEnginesResponsesDecode() async throws {
        let engine = FakeEngine()
        let id = "1abfc6b94cea2a1cb7312d373f8bb86fd95352dd525cedb56905a3eb354fccd8"
        engine.engine(socket.path, version: "1.56")
        engine.answer(socket.path, "/v1.56/containers/json", try fixture("containers"))
        engine.answer(socket.path, "/v1.56/containers/\(id)/stats?stream=false&one-shot=true", try fixture("stats"))

        let result = await read(engine)

        XCTAssertEqual(result, .read(engineID: "ENGINE", containers: [
            Container(
                id: id, name: "devtools-test", image: "nginx", runtime: "OrbStack",
                created: Date(timeIntervalSince1970: 1_795_765_903), memoryBytes: 11_313_152)
        ]))
    }

    func testAListOverOneMiBStillReads() async {
        let engine = FakeEngine()
        let padded = FakeEngine.container("a1", name: "web") + String(repeating: " ", count: 2 << 20)
        engine.engine(socket.path, containers: [padded])

        guard case .read(_, let containers) = await read(engine) else { return XCTFail("not read") }

        XCTAssertEqual(containers.map(\.name), ["web"])
    }

    func testMoreThan500ContainersIsUnreadableWithoutReadingStats() async {
        let engine = FakeEngine()
        engine.engine(socket.path, containers: (1...501).map { FakeEngine.container("c\($0)", name: "c\($0)") })

        let result = await read(engine)

        XCTAssertEqual(result, .unreadable)
        XCTAssertFalse(engine.paths.contains { $0.contains("/stats?") })
    }

    func test500ContainersRead() async {
        let engine = FakeEngine()
        engine.engine(socket.path, containers: (1...500).map { FakeEngine.container("c\($0)", name: "c\($0)") })

        guard case .read(_, let containers) = await read(engine) else { return XCTFail("not read") }

        XCTAssertEqual(containers.count, 500)
    }

    func testNameAndImageAreSanitized() async {
        let engine = FakeEngine()
        let longImage = String(repeating: "i", count: 2_000)
        engine.engine(
            socket.path,
            containers: [#"{"Id":"a1","Names":["/web\n\u202e\u001b[2J"],"Image":"\#(longImage)","Created":1}"#])

        guard case .read(_, let containers) = await read(engine) else { return XCTFail("not read") }

        XCTAssertEqual(containers.map(\.name), ["web\u{FFFD}\u{FFFD}\u{FFFD}[2J"])
        XCTAssertEqual(containers.map(\.image), [String(repeating: "i", count: 1_024)])
    }

    /// A response recorded from OrbStack's engine (Engine API 1.56, one nginx container).
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func stats(
        usage: UInt64?, inactiveFile: UInt64? = nil, totalInactiveFile: UInt64? = nil
    ) -> MemoryStats {
        let json = FakeEngine.memoryStats(
            usage: usage, inactiveFile: inactiveFile, totalInactiveFile: totalInactiveFile)
        return try! JSONDecoder.docker.decode(MemoryStats.self, from: Data(json.utf8))
    }
}
