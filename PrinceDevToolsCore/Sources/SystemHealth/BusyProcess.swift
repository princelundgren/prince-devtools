import Darwin

/// One of the user's processes that stayed over its share of a core for the whole CPU window.
public struct BusyProcess: Equatable, Sendable {
    public let name: String
    /// Its share of one core over the last interval, so it can exceed 100.
    public let percentOfCore: Double

    public init(name: String, percentOfCore: Double) {
        self.name = name
        self.percentOfCore = percentOfCore
    }
}

/// Follows each of the user's processes' share of one core from one scan to the next, and finds one
/// that stayed over a threshold for a whole window.
///
/// A process turns red once its intervals over the threshold, in a row, span the window; a quieter
/// interval starts it over. It stays red until an interval falls ``clearMarginPercent`` below the
/// threshold, or it exits. A pid whose CPU time fell is a reused pid and starts over. It keeps no
/// names: ``busiest(over:window:name:)`` asks for the name of a red process only.
struct BusyProcessTracker: Sendable {
    static let clearMarginPercent = 5.0
    /// Below this share no threshold the settings allow can hold a process, so it is not kept.
    static let keptFloorPercent = Double(HealthSettings.processCPUPercentRange.lowerBound) - clearMarginPercent
    /// The most intervals kept per process: the longest window, with room for late timer fires.
    static let keptIntervals = CPURing.capacity - 1

    private struct Interval: Sendable {
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant
        let percentOfCore: Double
    }

    private var lastScan: (time: ContinuousClock.Instant, cpuTimes: [pid_t: UInt64])?
    private var tracked: [pid_t: [Interval]] = [:]
    private var redPIDs: Set<pid_t> = []
    private var redSettings: (thresholdPercent: Int, window: Duration)?

    /// Adds the interval since the previous scan for every pid in both, from `cpuTimes` (each pid's
    /// cumulative CPU time in Mach time units); a pid missing from it, or below ``keptFloorPercent``,
    /// is forgotten. A scan no later than the last one recorded is ignored.
    mutating func record(_ cpuTimes: [pid_t: UInt64], at time: ContinuousClock.Instant, timebase: MachTimebase) {
        if let lastScan, time <= lastScan.time { return }
        defer { lastScan = (time, cpuTimes) }
        guard let lastScan else { return }
        let spanNanoseconds = Double((time - lastScan.time) / .nanoseconds(1))

        var stillTracked: [pid_t: [Interval]] = [:]
        for (pid, cpuTime) in cpuTimes {
            guard let earlier = lastScan.cpuTimes[pid], cpuTime >= earlier else { continue }
            let percent = Double(timebase.nanoseconds(cpuTime - earlier)) / spanNanoseconds * 100
            guard percent >= Self.keptFloorPercent else { continue }
            var intervals = tracked[pid] ?? []
            intervals.append(Interval(start: lastScan.time, end: time, percentOfCore: percent))
            if intervals.count > Self.keptIntervals { intervals.removeFirst() }
            stillTracked[pid] = intervals
        }
        tracked = stillTracked
        redPIDs.formIntersection(tracked.keys)
    }

    /// Forgets every process and the last scan, so the next scan only sets a baseline.
    mutating func reset() {
        lastScan = nil
        tracked = [:]
        redPIDs = []
    }

    /// The red process with the highest share in its last interval, or `nil` when none is red. A
    /// change of `thresholdPercent` or `window` drops every red first, so the new line is judged at
    /// once against the intervals kept. `name` is called for red pids only; one it can't name (it
    /// exited) is passed over. Ties go to the first name in sort order.
    mutating func busiest(
        over thresholdPercent: Int, window: Duration, name: (pid_t) -> String?
    ) -> BusyProcess? {
        if let redSettings, redSettings != (thresholdPercent, window) { redPIDs = [] }
        redSettings = (thresholdPercent, window)

        let threshold = Double(thresholdPercent)
        redPIDs = Set(tracked.compactMap { pid, intervals in
            guard let latest = intervals.last else { return nil }
            if redPIDs.contains(pid) && latest.percentOfCore > threshold - Self.clearMarginPercent { return pid }
            let run = intervals.reversed().prefix { $0.percentOfCore > threshold }
            guard let first = run.last, latest.end - first.start >= window else { return nil }
            return pid
        })

        let red = redPIDs.compactMap { pid -> (String, Double)? in
            guard let latest = tracked[pid]?.last, let processName = name(pid) else { return nil }
            return (processName, latest.percentOfCore)
        }
        guard let top = red.max(by: { ($0.1, $1.0) < ($1.1, $0.0) }) else { return nil }
        return BusyProcess(name: top.0, percentOfCore: top.1)
    }
}
