import Foundation

enum RuntimeRead: Equatable, Sendable {
    /// Nothing listens at the socket.
    case notRunning
    /// Something answered, but the read didn't yield a container list.
    case unreadable
    case read(engineID: String, containers: [Container])
}

/// The `memory_stats` object of a container's stats.
struct MemoryStats: Decodable, Equatable, Sendable {
    struct Detail: Decodable, Equatable, Sendable {
        let totalInactiveFile: UInt64?
        let inactiveFile: UInt64?
    }

    let usage: UInt64?
    let stats: Detail?
}

extension JSONDecoder {
    /// Decodes the Engine API's snake_case keys into camelCase properties.
    static var docker: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

enum DockerReader {
    private static let statsInFlight = 16
    /// More is a runtime the app can't read, which bounds a scan's length and the list's rows.
    static let mostContainers = 500
    private static let smallResponseLimit = 1 << 20
    private static let listResponseLimit = 16 << 20
    private static let statsResponseLimit = 64 << 10

    private struct Version: Decodable {
        let apiVersion: String
        enum CodingKeys: String, CodingKey { case apiVersion = "ApiVersion" }
    }

    private struct Info: Decodable {
        let id: String
        enum CodingKeys: String, CodingKey { case id = "ID" }
    }

    private struct Listed: Decodable {
        let id: String
        let names: [String]?
        let image: String
        let created: TimeInterval
        enum CodingKeys: String, CodingKey {
            case id = "Id", names = "Names", image = "Image", created = "Created"
        }
    }

    private struct Stats: Decodable { let memoryStats: MemoryStats? }

    /// Reads the running containers of the engine at `socket`: its `ApiVersion` from `/version`, its
    /// `ID` from `/info`, the container list, and each container's memory from its stats, fetched
    /// 16 at a time. A first request refused is `.notRunning`; any later failure, a body that isn't
    /// the expected JSON, an `ApiVersion` that isn't `<digits>.<digits>`, or more than
    /// ``mostContainers`` containers, is `.unreadable`. A container whose stats can't be read, or
    /// whose `Id` isn't a letter or digit followed by letters, digits, `_`, `.` and `-`, keeps a
    /// `nil` `memoryBytes`. Names and images pass through ``DisplayText``. An empty `ID` is
    /// replaced by a key made from the socket's path, so such an engine is never taken for
    /// another. Bodies are limited to 16 MiB for the list, 64 KiB for each container's stats and
    /// 1 MiB for the rest.
    static func read(_ socket: RuntimeSocket, transport: DockerTransport) async -> RuntimeRead {
        let version: String
        do {
            version = try await fetch(Version.self, "/version", socket, transport).apiVersion
        } catch .notRunning {
            return .notRunning
        } catch {
            return .unreadable
        }
        guard version.wholeMatch(of: /[0-9]+\.[0-9]+/) != nil else { return .unreadable }
        let prefix = "/v\(version)"
        do {
            let engineID = try await fetch(Info.self, "\(prefix)/info", socket, transport).id
            let listed = try await fetch(
                [Listed].self, "\(prefix)/containers/json", socket, transport, limit: listResponseLimit)
            guard listed.count <= mostContainers else { return .unreadable }
            let memory = await memoryByContainer(listed.map(\.id), prefix: prefix, socket, transport)
            let containers = listed.map { entry in
                Container(
                    id: entry.id, name: DisplayText.sanitized(name(of: entry)),
                    image: DisplayText.sanitized(entry.image), runtime: socket.runtime,
                    created: Date(timeIntervalSince1970: entry.created), memoryBytes: memory[entry.id])
            }
            return .read(engineID: engineID.isEmpty ? "socket \(socket.path)" : engineID, containers: containers)
        } catch {
            return .unreadable
        }
    }

    /// `usage` less its inactive file cache, as `docker stats` figures it: less
    /// `total_inactive_file` (cgroups v1), else less `inactive_file` (v2), each only while below
    /// `usage`; `nil` without `usage`, or above `Int64.max`, which no real container reaches.
    static func memoryInUse(_ stats: MemoryStats) -> UInt64? {
        guard let usage = stats.usage else { return nil }
        let reclaimable = [stats.stats?.totalInactiveFile, stats.stats?.inactiveFile]
            .compactMap { $0 }.first { $0 < usage } ?? 0
        let inUse = usage - reclaimable
        return inUse <= UInt64(Int64.max) ? inUse : nil
    }

    private static func name(of entry: Listed) -> String {
        guard let first = entry.names?.first else { return String(entry.id.prefix(12)) }
        return first.hasPrefix("/") ? String(first.dropFirst()) : first
    }

    private static func fetch<Body: Decodable>(
        _ type: Body.Type, _ path: String, _ socket: RuntimeSocket, _ transport: DockerTransport,
        limit: Int = smallResponseLimit
    ) async throws(SocketReadError) -> Body {
        let data = try await transport.get(socket.path, path, limit)
        do {
            return try JSONDecoder.docker.decode(Body.self, from: data)
        } catch {
            throw .failed("\(path) from \(socket.path) isn't the expected JSON")
        }
    }

    private static func memoryByContainer(
        _ ids: [String], prefix: String, _ socket: RuntimeSocket, _ transport: DockerTransport
    ) async -> [String: UInt64] {
        let memoryOf: @Sendable (String) async -> (String, UInt64?) = { id in
            guard id.wholeMatch(of: /[0-9A-Za-z][0-9A-Za-z_.-]*/) != nil else { return (id, nil) }
            let path = "\(prefix)/containers/\(id)/stats?stream=false&one-shot=true"
            let stats = try? await fetch(Stats.self, path, socket, transport, limit: statsResponseLimit)
            return (id, stats?.memoryStats.flatMap(memoryInUse))
        }
        return await withTaskGroup(of: (String, UInt64?).self) { group in
            var waiting = ids.makeIterator()
            for _ in 0..<statsInFlight {
                guard let id = waiting.next() else { break }
                group.addTask { await memoryOf(id) }
            }
            var memory: [String: UInt64] = [:]
            while let (id, bytes) = await group.next() {
                if let bytes { memory[id] = bytes }
                if let next = waiting.next() { group.addTask { await memoryOf(next) } }
            }
            return memory
        }
    }
}
