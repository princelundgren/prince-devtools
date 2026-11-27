import Foundation
import Observation

/// Keeps ``scan`` current, and only while someone looks: one scan when the panel opens, for the
/// card, and one every 2 s while the list is shown. At most one scan runs at a time: an opening,
/// a showing or a tick while one runs starts none, and that scan's result is the one applied.
/// Nothing is scanned while the panel is closed. Every scan runs at background priority and
/// nothing waits on it.
///
/// The app forwards the panel's opening and closing and the list's showing and hiding. A scan's
/// socket reads are not cancelled: one still running when the list hides or the panel closes
/// finishes and is applied. With 2 s per request, three requests before the stats and at most 500
/// containers read 16 at a time, that is within about 70 s.
@MainActor @Observable
public final class ContainerMonitor {
    /// The latest scan applied; `nil` until the first one finishes.
    public private(set) var scan: ContainerScan?
    /// Whether the list, not the cards, is what the panel shows.
    public private(set) var isListShown = false

    private let source: ContainerSource
    private let listTimerInterval: TimeInterval
    @ObservationIgnored private var listTimer: Timer?
    @ObservationIgnored private var scanInFlight: Task<Void, Never>?

    /// A monitor that reads `source`; it reads nothing until ``panelOpened()`` or ``showList()``.
    public convenience init(source: ContainerSource) {
        self.init(source: source, listTimerInterval: 2)
    }

    /// As ``init(source:)``, with the list's timer ticking every `listTimerInterval` seconds.
    init(source: ContainerSource, listTimerInterval: TimeInterval) {
        self.source = source
        self.listTimerInterval = listTimerInterval
    }

    var isListTimerArmed: Bool { listTimer != nil }

    /// Scans once, unless a scan still runs, so the card opens on current containers, and shows
    /// the cards.
    public func panelOpened() {
        hideList()
        startScan()
    }

    /// Stops the 2 s timer and hides the list. A scan still running finishes and is applied.
    public func panelClosed() {
        hideList()
    }

    /// Shows the list, scans at once unless a scan still runs, and rescans every 2 s until
    /// ``hideList()`` or ``panelClosed()``.
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

    /// The 2 s timer's tick: a scan, unless one is still running.
    func listTimerFired() {
        startScan()
    }

    func scansFinished() async {
        await scanInFlight?.value
    }

    private func startScan() {
        guard scanInFlight == nil else { return }
        scanInFlight = Task(priority: .background) { [source] in
            let result = await ContainerList.scan(source)
            scanInFlight = nil
            scan = result
        }
    }

    private func armListTimer() {
        listTimer?.invalidate()
        let timer = Timer(timeInterval: listTimerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.listTimerFired() }
        }
        timer.tolerance = listTimerInterval / 10
        RunLoop.main.add(timer, forMode: .common)
        listTimer = timer
    }
}
