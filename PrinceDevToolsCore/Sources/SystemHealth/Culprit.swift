import Darwin

/// The ratio that converts Mach absolute time units to nanoseconds.
public struct MachTimebase: Sendable {
    /// Numerator of the Mach-units-to-nanoseconds ratio.
    public let numer: UInt32
    /// Denominator of the Mach-units-to-nanoseconds ratio; never zero.
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = numer
        self.denom = denom
    }

    /// The timebase of this machine, from `mach_timebase_info`.
    public static var current: MachTimebase {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MachTimebase(numer: info.numer, denom: info.denom)
    }

    /// Converts `machTime` to nanoseconds without overflowing, saturating at `UInt64.max`.
    public func nanoseconds(_ machTime: UInt64) -> UInt64 {
        UInt64(clamping: UInt128(machTime) * UInt128(numer) / UInt128(denom))
    }
}

/// One process at one moment.
public struct ProcessUsage: Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    /// The process's physical footprint, in bytes.
    public let footprintBytes: UInt64
    /// Cumulative user plus system CPU time in Mach time units.
    public let cpuTime: UInt64

    public init(pid: pid_t, name: String, footprintBytes: UInt64, cpuTime: UInt64) {
        self.pid = pid
        self.name = name
        self.footprintBytes = footprintBytes
        self.cpuTime = cpuTime
    }
}

/// The process (or the lack of one) behind a health message.
public enum Culprit: Sendable, Equatable {
    case memory(name: String, bytes: UInt64)
    /// `percentOfCore` is a share of one core, so it can exceed 100.
    case cpu(name: String, percentOfCore: Double)
    case processes(name: String, count: Int)
    /// The user's processes account for under half of the machine's busy time.
    case mostlySystem
}

/// Picks the process behind a message. A tie goes to the first name in sort order, so repeated
/// scans pick the same process.
public enum CulpritFinder {
    /// The process with the largest footprint, or `nil` for an empty scan.
    public static func memory(_ scan: [ProcessUsage]) -> Culprit? {
        guard let top = scan.max(by: { ($0.footprintBytes, $1.name) < ($1.footprintBytes, $0.name) }) else {
            return nil
        }
        return .memory(name: top.name, bytes: top.footprintBytes)
    }

    /// The executable name with the most instances, or `nil` for an empty scan.
    public static func processes(_ scan: [ProcessUsage]) -> Culprit? {
        let counts = Dictionary(grouping: scan, by: \.name).mapValues(\.count)
        guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        return .processes(name: top.key, count: top.value)
    }

    /// The process that used the most CPU between two scans.
    ///
    /// Only pids present in both scans count, and a pid whose `cpuTime` fell (a reused pid) is
    /// ignored. `interval` is the measured span between the scans, and `machineBusyNanoseconds` the
    /// CPU time all cores spent busy over it. Returns `.mostlySystem` when the counted processes
    /// used under half of that; otherwise the process with the largest positive delta. Returns `nil`
    /// when `interval` is empty or there is no positive delta to report.
    public static func cpu(
        before: [ProcessUsage],
        after: [ProcessUsage],
        interval: Duration,
        timebase: MachTimebase,
        machineBusyNanoseconds: UInt64
    ) -> Culprit? {
        let intervalNanoseconds = Double(interval.components.seconds) * 1e9
            + Double(interval.components.attoseconds) / 1e9
        guard intervalNanoseconds > 0 else { return nil }

        let earlierCPUTime = Dictionary(before.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { _, last in last })
        let deltas: [(name: String, nanoseconds: UInt64)] = after.compactMap { process in
            guard let earlier = earlierCPUTime[process.pid], process.cpuTime >= earlier else { return nil }
            return (process.name, timebase.nanoseconds(process.cpuTime - earlier))
        }

        let userNanoseconds = deltas.reduce(UInt128(0)) { $0 + UInt128($1.nanoseconds) }
        if userNanoseconds * 2 < UInt128(machineBusyNanoseconds) { return .mostlySystem }

        guard let top = deltas.max(by: { ($0.nanoseconds, $1.name) < ($1.nanoseconds, $0.name) }),
            top.nanoseconds > 0
        else { return nil }
        return .cpu(name: top.name, percentOfCore: Double(top.nanoseconds) / intervalNanoseconds * 100)
    }
}
