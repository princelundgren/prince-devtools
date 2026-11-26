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
        .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
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
            isParentGone: false)
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
