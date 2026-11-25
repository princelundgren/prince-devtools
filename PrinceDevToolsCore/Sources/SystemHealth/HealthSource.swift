/// Where ``HealthMonitor`` gets its readings, its clock and its pause, so tests can supply their own.
/// The read closures follow ``SystemReader``'s contract: cheap, non-blocking, `nil` when unreadable.
public struct HealthSource: Sendable {
    public var memoryLevel: @Sendable () -> MemoryLevel?
    public var swapUsedBytes: @Sendable () -> UInt64?
    public var cpuTicks: @Sendable () -> CPUTicks?
    public var diskFreeBytes: @Sendable () -> UInt64?
    public var processCount: @Sendable () -> Int?
    public var processLimit: @Sendable () -> Int?
    public var thermalLevel: @Sendable () -> ThermalLevel
    /// The one read that walks every process, so callers keep it off the main actor.
    public var processUsages: @Sendable () -> [ProcessUsage]
    public var now: @Sendable () -> ContinuousClock.Instant
    /// Waits about `duration`; returns early if the calling task is cancelled.
    public var pause: @Sendable (Duration) async -> Void
    public var timebase: MachTimebase
    /// The unit of ``CPUTicks``.
    public var ticksPerSecond: Int

    public init(
        memoryLevel: @escaping @Sendable () -> MemoryLevel?,
        swapUsedBytes: @escaping @Sendable () -> UInt64?,
        cpuTicks: @escaping @Sendable () -> CPUTicks?,
        diskFreeBytes: @escaping @Sendable () -> UInt64?,
        processCount: @escaping @Sendable () -> Int?,
        processLimit: @escaping @Sendable () -> Int?,
        thermalLevel: @escaping @Sendable () -> ThermalLevel,
        processUsages: @escaping @Sendable () -> [ProcessUsage],
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        pause: @escaping @Sendable (Duration) async -> Void,
        timebase: MachTimebase,
        ticksPerSecond: Int
    ) {
        self.memoryLevel = memoryLevel
        self.swapUsedBytes = swapUsedBytes
        self.cpuTicks = cpuTicks
        self.diskFreeBytes = diskFreeBytes
        self.processCount = processCount
        self.processLimit = processLimit
        self.thermalLevel = thermalLevel
        self.processUsages = processUsages
        self.now = now
        self.pause = pause
        self.timebase = timebase
        self.ticksPerSecond = ticksPerSecond
    }

    /// This machine: ``SystemReader``'s reads, the continuous clock and `Task.sleep(for:)`.
    public static let live = HealthSource(
        memoryLevel: SystemReader.memoryLevel,
        swapUsedBytes: SystemReader.swapUsedBytes,
        cpuTicks: SystemReader.cpuTicks,
        diskFreeBytes: SystemReader.diskFreeBytes,
        processCount: SystemReader.processCount,
        processLimit: SystemReader.processLimit,
        thermalLevel: SystemReader.thermalLevel,
        processUsages: SystemReader.processUsages,
        now: { ContinuousClock.now },
        pause: { duration in try? await Task.sleep(for: duration) },
        timebase: .current,
        ticksPerSecond: SystemReader.ticksPerSecond)
}
