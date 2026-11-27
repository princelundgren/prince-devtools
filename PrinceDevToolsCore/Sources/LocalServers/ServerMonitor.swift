import Foundation
import Observation

/// One scan's result: the servers it found and when.
public struct ServerScan: Equatable, Sendable {
    public let servers: [Server]
    public let time: Date

    public init(servers: [Server], time: Date) {
        self.servers = servers
        self.time = time
    }
}

/// Keeps ``scan`` current, and only while someone looks: one scan when the panel opens, for the
/// card, and one every 2 s while the list is shown, unless a scan still runs. Nothing is scanned
/// while the panel is closed.
/// Every scan runs at background priority and nothing waits on it; a scan that finishes after a
/// newer one was applied is dropped.
///
/// The app forwards the panel's opening and closing and the list's showing and hiding.
@MainActor @Observable
public final class ServerMonitor {
    private static let listTimerInterval: TimeInterval = 2
    private static let listTimerTolerance: TimeInterval = 0.2

    /// The latest scan applied; `nil` until the first one finishes.
    public private(set) var scan: ServerScan?
    /// Whether the list, not the cards, is what the panel shows.
    public private(set) var isListShown = false

    /// The folder under which a process counts as a server's.
    public var homeFolder: String { source.homeFolder }

    private let source: ServerSource
    @ObservationIgnored private var listTimer: Timer?
    @ObservationIgnored private var lastStartedScan = 0
    @ObservationIgnored private var lastAppliedScan = 0
    @ObservationIgnored private var scansInFlight: [Int: Task<Void, Never>] = [:]

    /// A monitor that reads `source`; it reads nothing until ``panelOpened()`` or ``showList()``.
    public init(source: ServerSource) {
        self.source = source
    }

    var isListTimerArmed: Bool { listTimer != nil }

    /// Scans once, so the card opens on current servers, and shows the cards.
    public func panelOpened() {
        hideList()
        startScan()
    }

    /// Stops the 2 s timer and hides the list. A scan still running finishes and is applied.
    public func panelClosed() {
        hideList()
    }

    /// Shows the list, scans at once and rescans every 2 s until ``hideList()`` or ``panelClosed()``.
    public func showList() {
        isListShown = true
        startScan()
        armListTimer()
    }

    /// Hides the list and stops the 2 s timer.
    public func hideList() {
        isListShown = false
        listTimer?.invalidate()
        listTimer = nil
    }

    /// Asks `server` to stop if its pid is still the process the scan read (``ServerStop``), then
    /// scans again at once; the list's timer catches a process that exits later.
    public func stop(_ server: Server, with signal: StopSignal) -> StopResult {
        let result = ServerStop.stop(server, with: signal, source: source)
        startScan()
        return result
    }

    func scansFinished() async {
        for scan in scansInFlight.values { await scan.value }
    }

    /// A tick of the list's timer: a scan, unless one still runs.
    func listTimerFired() {
        guard scansInFlight.isEmpty else { return }
        startScan()
    }

    private func startScan() {
        lastStartedScan += 1
        let number = lastStartedScan
        scansInFlight[number] = Task(priority: .background) { [source] in
            let result = await Self.scan(source)
            scansInFlight[number] = nil
            guard number > lastAppliedScan else { return }
            lastAppliedScan = number
            scan = result
        }
    }

    @concurrent
    private static func scan(_ source: ServerSource) async -> ServerScan {
        ServerScan(servers: ServerList.servers(from: source), time: source.now())
    }

    private func armListTimer() {
        listTimer?.invalidate()
        let timer = Timer(timeInterval: Self.listTimerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.listTimerFired() }
        }
        timer.tolerance = Self.listTimerTolerance
        RunLoop.main.add(timer, forMode: .common)
        listTimer = timer
    }
}
