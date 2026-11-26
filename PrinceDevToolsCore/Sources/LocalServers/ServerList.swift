import Darwin
import Foundation

/// Turns one scan of the user's listening sockets into the server list.
public enum ServerList {
    /// The servers someone started: a listening socket on a port below the kernel's random-port
    /// floor, held by a process whose folder is the home folder or below it. One row per socket,
    /// shown as its oldest holder, then one row per process and port.
    public static func servers(from source: ServerSource) -> [Server] {
        let floor = source.portFloor()
        let holders = Dictionary(grouping: source.listeningSockets().filter { $0.port < floor }, by: \.socketHandle)
            .compactMap { _, sockets in oldestHolder(of: sockets, source: source) }
            .filter { $0.record.folder.isInHomeFolder(source.homeFolder) }
        let rows = Dictionary(grouping: holders) { PIDAndPort(pid: $0.record.pid, port: $0.port) }
        return rows.map { key, holders in
            server(holders[0].record, port: key.port, addresses: holders.map(\.address), source: source)
        }
        .sorted(by: listOrder)
    }

    /// Parent gone first, then by port, then by pid.
    private static func listOrder(_ first: Server, _ second: Server) -> Bool {
        guard first.isParentGone == second.isParentGone else { return first.isParentGone }
        return (first.port, first.pid) < (second.port, second.pid)
    }

    private static let longestChain = 64

    /// Whether the process that started `process` is gone: climbing the parent chain, the first
    /// process whose parent is launchd (pid 1) has a folder in `home`, as a wrapper the ended
    /// session left behind does, and an app launchd starts, in `/`, doesn't. A parent `lookup`
    /// can't read (another user's), a loop, or a chain over 64 long ends the walk as not gone.
    static func isParentGone(
        _ process: ProcessRecord, home: String, lookup: (pid_t) -> ProcessRecord?
    ) -> Bool {
        var current = process
        var seen: Set<pid_t> = [process.pid]
        for _ in 0..<longestChain {
            if current.parentPID == 1 { return current.folder.isInHomeFolder(home) }
            guard let parent = lookup(current.parentPID), seen.insert(parent.pid).inserted else { return false }
            current = parent
        }
        return false
    }

    private struct PIDAndPort: Hashable {
        let pid: pid_t
        let port: UInt16
    }

    private struct Holder {
        let record: ProcessRecord
        let port: UInt16
        let address: String
    }

    /// The earliest-started process holding one socket, the lowest pid on a tie; `nil` when every
    /// holder has exited.
    private static func oldestHolder(of sockets: [ListeningSocket], source: ServerSource) -> Holder? {
        let socket = sockets[0]
        let oldest = Set(sockets.map(\.pid)).compactMap(source.process)
            .min { ($0.startTime, $0.pid) < ($1.startTime, $1.pid) }
        return oldest.map { Holder(record: $0, port: socket.port, address: socket.address) }
    }

    private static func server(
        _ record: ProcessRecord, port: UInt16, addresses: [String], source: ServerSource
    ) -> Server {
        let folderPath: String? = if case .path(let path, _) = record.folder, !path.isEmpty { path } else { nil }
        return Server(
            pid: record.pid, name: source.processName(record.pid), port: port,
            addresses: Set(addresses).sorted(), folderPath: folderPath,
            isFolderGone: isFolderGone(record.folder, check: source.checkFolder), startTime: record.startTime,
            isParentGone: isParentGone(record, home: source.homeFolder, lookup: source.process))
    }

    private static func isFolderGone(_ folder: FolderReading, check: (String) -> FolderCheck) -> Bool {
        guard case .path(let path, let identity) = folder, !path.isEmpty else { return true }
        switch check(path) {
        case .missing: return true
        case .exists(let found): return found != identity
        case .unknown: return false
        }
    }
}
