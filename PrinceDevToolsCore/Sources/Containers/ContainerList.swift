import Foundation

public enum ContainerList {
    /// Reads every socket in parallel and merges the runtimes into one scan. A runtime that isn't
    /// running is left out; one that answered but couldn't be read is named in `unreadableRuntimes`,
    /// once however many of its sockets fail. A failed socket has no engine ID to compare, so it is
    /// named even when another socket read its engine.
    /// An engine already read under an earlier socket is skipped, so its containers count once under
    /// that socket's runtime name. `runtimesRead` and `unreadableRuntimes` keep socket order; the
    /// containers sort by memory, largest first, unknown last, ties by name.
    @concurrent
    public static func scan(_ source: ContainerSource) async -> ContainerScan {
        let sockets = source.sockets()
        let reads = await withTaskGroup(of: (Int, RuntimeRead).self) { group in
            for (index, socket) in sockets.enumerated() {
                group.addTask { (index, await DockerReader.read(socket, transport: source.transport)) }
            }
            var reads: [(Int, RuntimeRead)] = []
            for await read in group { reads.append(read) }
            return reads.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var containers: [Container] = []
        var runtimesRead: [String] = []
        var unreadable: [String] = []
        var seenEngines = Set<String>()
        for (socket, read) in zip(sockets, reads) {
            switch read {
            case .notRunning:
                break
            case .unreadable:
                if !unreadable.contains(socket.runtime) { unreadable.append(socket.runtime) }
            case .read(let engineID, let found):
                guard seenEngines.insert(engineID).inserted else { continue }
                runtimesRead.append(socket.runtime)
                containers += found
            }
        }
        containers.sort(by: isListedBefore)
        return ContainerScan(
            containers: containers, runtimesRead: runtimesRead, unreadableRuntimes: unreadable, time: source.now())
    }

    private static func isListedBefore(_ a: Container, _ b: Container) -> Bool {
        switch (a.memoryBytes, b.memoryBytes) {
        case let (x?, y?) where x != y: return x > y
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a.name < b.name
        }
    }
}
