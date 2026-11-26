import Foundation
import System

/// The Servers card's strings.
public struct ServerCard: Equatable, Sendable {
    public let value: String
    public let detail: String?
    /// "Servers, <value>[, <detail>]".
    public let accessibilityLabel: String
}

/// One row's strings.
public struct ServerRowText: Equatable, Sendable {
    /// ":8000", never grouped by the locale.
    public let port: String
    /// The process name, or "pid 4242" when it can't be read.
    public let name: String
    /// The folder's last component, or "folder gone".
    public let folder: String
    /// "4242", never grouped by the locale.
    public let pid: String
    /// "59 min", "10 h", "3 d", rounded down.
    public let running: String
    /// `running` in words ("10 hours"), for its cell's VoiceOver label, since VoiceOver reads "h" as
    /// a letter.
    public let spokenRunning: String
    /// The row's help tag and VoiceOver label: port, process, pid, folder, addresses, time running
    /// in words ("10 hours") and whether it is orphaned.
    public let description: String
}

/// The localhost servers tool's wording. Counts and times are formatted for `locale`; ports and
/// pids are not, and the words are English.
public enum ServerText {
    public static let title = "Servers"
    public static let orphanedHelp = "Orphaned: the process that started it has exited"
    public static let emptyList = "No servers listening"
    private static let folderGone = "folder gone"

    /// The card for a scan's servers; `nil` before the first scan.
    public static func card(_ servers: [Server]?, locale: Locale) -> ServerCard {
        guard let servers else { return card(value: "Not known yet", detail: nil) }
        let value = servers.isEmpty ? "None listening" : "\(integer(servers.count, locale: locale)) listening"
        let orphaned = servers.count(where: \.isParentGone)
        return card(value: value, detail: orphaned > 0 ? "\(integer(orphaned, locale: locale)) orphaned" : nil)
    }

    /// The row for `server`, its time running counted up to `now`, with `home` written `~`.
    public static func row(_ server: Server, now: Date, home: String, locale: Locale) -> ServerRowText {
        let name = server.name ?? "pid \(server.pid)"
        let (running, spokenRunning) = running(since: server.startTime, now: now, locale: locale)
        let fullFolder = [server.folderPath.map { tildePath($0, home: home) }, server.isFolderGone ? folderGone : nil]
            .compactMap { $0 }.joined(separator: ", ")
        let description = [
            "Port \(server.port)", name, "pid \(server.pid)", fullFolder,
            "listening on \(server.addresses.formatted(.list(type: .and).locale(locale)))", "running \(spokenRunning)",
            server.isParentGone ? "orphaned" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        return ServerRowText(
            port: ":\(server.port)", name: name, folder: shortFolder(server), pid: "\(server.pid)", running: running,
            spokenRunning: spokenRunning, description: description)
    }

    private static func card(value: String, detail: String?) -> ServerCard {
        ServerCard(
            value: value, detail: detail,
            accessibilityLabel: ([title, value] + [detail].compactMap { $0 }).joined(separator: ", "))
    }

    private static func shortFolder(_ server: Server) -> String {
        guard !server.isFolderGone, let path = server.folderPath else { return folderGone }
        return FilePath(path).lastComponent?.string ?? path
    }

    private static func tildePath(_ path: String, home: String) -> String {
        var relative = FilePath(path)
        guard relative.removePrefix(FilePath(home)) else { return path }
        return relative.isEmpty ? "~" : "~/\(relative)"
    }

    /// "10 h" to show and "10 hours" to speak, since VoiceOver reads "h" as a letter.
    private static func running(since start: Date, now: Date, locale: Locale) -> (shown: String, spoken: String) {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        let (count, symbol, unit) = minutes < 60 ? (minutes, "min", "minute")
            : minutes < 24 * 60 ? (minutes / 60, "h", "hour") : (minutes / (24 * 60), "d", "day")
        let number = integer(count, locale: locale)
        return ("\(number) \(symbol)", "\(number) \(unit)\(count == 1 ? "" : "s")")
    }

    private static func integer(_ number: Int, locale: Locale) -> String {
        number.formatted(.number.locale(locale))
    }
}
