/// Cumulative CPU time counters summed over all cores, as the kernel reports them.
///
/// The counters are 32-bit and wrap; differences must go through ``CPURing`` or `&-`.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    func busyAndTotal(since old: CPUTicks) -> (busy: UInt64, total: UInt64) {
        let busy = UInt64(user &- old.user) + UInt64(system &- old.system) + UInt64(nice &- old.nice)
        return (busy, busy + UInt64(idle &- old.idle))
    }
}

/// A reading of the CPU counters and the instant it was taken.
public struct CPUSample: Sendable {
    public let ticks: CPUTicks
    public let time: ContinuousClock.Instant

    public init(ticks: CPUTicks, time: ContinuousClock.Instant) {
        self.ticks = ticks
        self.time = time
    }
}

/// The result of averaging CPU use over a window.
public enum CPUAverage: Equatable, Sendable {
    /// Fewer than two samples, or no ticks elapsed between them.
    case notKnown
    /// The ring does not yet reach back a full window; `span` is the time actually covered.
    case partial(percent: Double, span: Duration)
    /// Some sample is at least one window old; `span` is the time actually covered (at least the window).
    case full(percent: Double, span: Duration)
}

/// A fixed-capacity history of CPU samples that averages busy time over a window.
///
/// The capacity of 17 samples covers 16 one-minute intervals, enough for the 15 minute maximum
/// window even when timer fires are late.
public struct CPURing: Sendable {
    public static let capacity = 17

    private var samples: [CPUSample] = []

    public init() {}

    /// Adds `sample` as the newest, dropping the oldest once the ring holds ``capacity`` samples.
    public mutating func append(_ sample: CPUSample) {
        if samples.count == Self.capacity {
            samples.removeFirst()
        }
        samples.append(sample)
    }

    /// Forgets every sample, so the next average is `.notKnown` until two new ones arrive (after sleep, say).
    public mutating func removeAll() {
        samples.removeAll()
    }

    /// Average busy percentage (user + system + nice, 0 to 100) over `window`.
    ///
    /// Divides by the ticks elapsed between the samples used, which track real time, so uneven timer
    /// spacing does not skew it.
    /// Uses the newest sample at least `window` older than the newest; when none is, the oldest sample
    /// gives a `.partial` result.
    public func average(over window: Duration) -> CPUAverage {
        guard let newest = samples.last, samples.count >= 2 else { return .notKnown }
        let fullStart = samples.dropLast().last { newest.time - $0.time >= window }
        guard let start = fullStart ?? samples.first else { return .notKnown }
        let (busy, total) = newest.ticks.busyAndTotal(since: start.ticks)
        guard total > 0 else { return .notKnown }
        let percent = Double(busy) / Double(total) * 100
        let span = newest.time - start.time
        return fullStart == nil ? .partial(percent: percent, span: span) : .full(percent: percent, span: span)
    }
}
