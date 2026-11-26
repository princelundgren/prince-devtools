import Foundation

/// The user's health thresholds, with the design's defaults and ranges.
public struct HealthSettings: Equatable, Sendable {
    /// The pressure level at which memory turns red: `.warning` or `.critical`, never `.normal`.
    public var memoryRedLevel: MemoryLevel
    /// The whole-machine CPU share, in percent, above which CPU turns red.
    public var cpuPercent: Int
    /// The minutes the CPU average covers.
    public var cpuWindowMinutes: Int
    /// The share of one core, in percent, that one of the user's processes must pass in every
    /// minute of the CPU window to turn CPU red.
    public var processCPUPercent: Int
    /// The free space, in gigabytes, below which disk turns red.
    public var diskFreeGB: Int
    /// The share of the per-user process limit, in percent, above which processes turn red.
    public var processSharePercent: Int

    /// The thresholds a fresh install starts with.
    public static let defaults = HealthSettings(
        memoryRedLevel: .critical, cpuPercent: 80, cpuWindowMinutes: 1, processCPUPercent: 90,
        diskFreeGB: 30, processSharePercent: 80)

    /// The accepted values of ``cpuPercent``.
    public static let cpuPercentRange = 50...100
    /// The accepted values of ``cpuWindowMinutes``.
    public static let cpuWindowRange = 1...15
    /// The accepted values of ``processCPUPercent``.
    public static let processCPUPercentRange = 50...400
    /// The accepted values of ``diskFreeGB``.
    public static let diskFreeRange = 5...500
    /// The accepted values of ``processSharePercent``.
    public static let processShareRange = 50...95

    /// ``cpuWindowMinutes`` as a duration.
    public var cpuWindow: Duration { .seconds(cpuWindowMinutes * 60) }

    public init(memoryRedLevel: MemoryLevel, cpuPercent: Int, cpuWindowMinutes: Int, processCPUPercent: Int,
                diskFreeGB: Int, processSharePercent: Int) {
        self.memoryRedLevel = memoryRedLevel
        self.cpuPercent = cpuPercent
        self.cpuWindowMinutes = cpuWindowMinutes
        self.processCPUPercent = processCPUPercent
        self.diskFreeGB = diskFreeGB
        self.processSharePercent = processSharePercent
    }

    /// Reads every threshold from `defaults`. A missing value, or one that is not a whole number,
    /// becomes the default; a whole number outside its range is clamped (a Bool reads as 0 or 1).
    /// A bad stored value never disables a check.
    public init(reading defaults: UserDefaults) {
        let fallback = Self.defaults
        let storedLevel = defaults.object(forKey: Key.memoryRedLevel) as? Int
        self.init(
            memoryRedLevel: storedLevel.flatMap(MemoryLevel.init(rawValue:))
                .flatMap { [.warning, .critical].contains($0) ? $0 : nil } ?? fallback.memoryRedLevel,
            cpuPercent: Self.read(Key.cpuPercent, in: Self.cpuPercentRange, from: defaults, default: fallback.cpuPercent),
            cpuWindowMinutes: Self.read(Key.cpuWindowMinutes, in: Self.cpuWindowRange, from: defaults, default: fallback.cpuWindowMinutes),
            processCPUPercent: Self.read(Key.processCPUPercent, in: Self.processCPUPercentRange, from: defaults, default: fallback.processCPUPercent),
            diskFreeGB: Self.read(Key.diskFreeGB, in: Self.diskFreeRange, from: defaults, default: fallback.diskFreeGB),
            processSharePercent: Self.read(Key.processSharePercent, in: Self.processShareRange, from: defaults, default: fallback.processSharePercent))
    }

    /// Writes all six thresholds as integers; `init(reading:)` reads them back.
    public func save(to defaults: UserDefaults) {
        defaults.set(memoryRedLevel.rawValue, forKey: Key.memoryRedLevel)
        defaults.set(cpuPercent, forKey: Key.cpuPercent)
        defaults.set(cpuWindowMinutes, forKey: Key.cpuWindowMinutes)
        defaults.set(processCPUPercent, forKey: Key.processCPUPercent)
        defaults.set(diskFreeGB, forKey: Key.diskFreeGB)
        defaults.set(processSharePercent, forKey: Key.processSharePercent)
    }

    private static func read(_ key: String, in range: ClosedRange<Int>, from defaults: UserDefaults,
                             default fallback: Int) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int else { return fallback }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    private enum Key {
        static let memoryRedLevel = "systemHealth.memoryRedLevel"
        static let cpuPercent = "systemHealth.cpuPercent"
        static let cpuWindowMinutes = "systemHealth.cpuWindowMinutes"
        static let processCPUPercent = "systemHealth.processCPUPercent"
        static let diskFreeGB = "systemHealth.diskFreeGB"
        static let processSharePercent = "systemHealth.processSharePercent"
    }
}
