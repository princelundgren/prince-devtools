/// Apple's memory pressure level, with the raw values of `kern.memorystatus_vm_pressure_level`.
public enum MemoryLevel: Int, Comparable, Sendable, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4

    /// Returns `nil` for a value the kernel is not documented to report.
    public init?(sysctlValue: Int32) {
        self.init(rawValue: Int(sysctlValue))
    }

    public static func < (lhs: MemoryLevel, rhs: MemoryLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
