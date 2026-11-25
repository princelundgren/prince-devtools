import Foundation

/// The user's health thresholds, with the design's defaults and ranges.
public struct HealthSettings: Equatable, Sendable {
    /// The pressure level at which memory turns red: `.warning` or `.critical`, never `.normal`.
    public var memoryRedLevel: MemoryLevel
    public var cpuPercent: Int
    public var cpuWindowMinutes: Int
    public var diskFreeGB: Int
    public var processSharePercent: Int

    public static let defaults = HealthSettings(
        memoryRedLevel: .critical, cpuPercent: 80, cpuWindowMinutes: 5,
        diskFreeGB: 30, processSharePercent: 80)

    public static let cpuPercentRange = 50...100
    public static let cpuWindowRange = 3...15
    public static let diskFreeRange = 5...500
    public static let processShareRange = 50...95

    public var cpuWindow: Duration { .seconds(cpuWindowMinutes * 60) }

    public init(memoryRedLevel: MemoryLevel, cpuPercent: Int, cpuWindowMinutes: Int,
                diskFreeGB: Int, processSharePercent: Int) {
        self.memoryRedLevel = memoryRedLevel
        self.cpuPercent = cpuPercent
        self.cpuWindowMinutes = cpuWindowMinutes
        self.diskFreeGB = diskFreeGB
        self.processSharePercent = processSharePercent
    }

    /// Reads every threshold from `defaults`. A missing or non-integer value becomes the default and
    /// an integer outside its range is clamped, so a bad stored value never disables a check.
    public init(reading defaults: UserDefaults) {
        let fallback = Self.defaults
        let storedLevel = defaults.object(forKey: Key.memoryRedLevel) as? Int
        self.init(
            memoryRedLevel: storedLevel.flatMap(MemoryLevel.init(rawValue:))
                .flatMap { [.warning, .critical].contains($0) ? $0 : nil } ?? fallback.memoryRedLevel,
            cpuPercent: Self.read(Key.cpuPercent, in: Self.cpuPercentRange, from: defaults, default: fallback.cpuPercent),
            cpuWindowMinutes: Self.read(Key.cpuWindowMinutes, in: Self.cpuWindowRange, from: defaults, default: fallback.cpuWindowMinutes),
            diskFreeGB: Self.read(Key.diskFreeGB, in: Self.diskFreeRange, from: defaults, default: fallback.diskFreeGB),
            processSharePercent: Self.read(Key.processSharePercent, in: Self.processShareRange, from: defaults, default: fallback.processSharePercent))
    }

    /// Writes all five thresholds as integers; `init(reading:)` reads them back.
    public func save(to defaults: UserDefaults) {
        defaults.set(memoryRedLevel.rawValue, forKey: Key.memoryRedLevel)
        defaults.set(cpuPercent, forKey: Key.cpuPercent)
        defaults.set(cpuWindowMinutes, forKey: Key.cpuWindowMinutes)
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
        static let diskFreeGB = "systemHealth.diskFreeGB"
        static let processSharePercent = "systemHealth.processSharePercent"
    }
}
