import Foundation

/// The system's thermal state, folded to normal, serious and critical; the last two warrant a message.
public enum ThermalLevel: Sendable, Equatable {
    case normal, serious, critical

    /// `.nominal` and `.fair` are `.normal`; an unknown future state is treated as `.critical`.
    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal, .fair: self = .normal
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}

/// One reading of every metric; `nil` or `.notKnown` means not read yet or not readable. Thermal has no
/// unknown state and defaults to `.normal`.
public struct HealthReadings: Equatable, Sendable {
    public var memory: MemoryLevel?
    /// Shown as the memory card's second line; the evaluator does not read it.
    public var swapUsedBytes: UInt64?
    public var cpu: CPUAverage
    public var diskFreeBytes: UInt64?
    public var processCount: Int?
    public var processLimit: Int?
    public var thermal: ThermalLevel

    public init(memory: MemoryLevel? = nil, swapUsedBytes: UInt64? = nil, cpu: CPUAverage = .notKnown,
                diskFreeBytes: UInt64? = nil, processCount: Int? = nil, processLimit: Int? = nil,
                thermal: ThermalLevel = .normal) {
        self.memory = memory
        self.swapUsedBytes = swapUsedBytes
        self.cpu = cpu
        self.diskFreeBytes = diskFreeBytes
        self.processCount = processCount
        self.processLimit = processLimit
        self.thermal = thermal
    }
}

public enum CardState: Sendable, Equatable {
    case notKnown, green, yellow, red
}

/// What a message is about; the raw value is the order messages appear in.
public enum HealthCause: Int, CaseIterable, Comparable, Sendable {
    case memory, disk, processes, cpu, thermal

    public static func < (lhs: HealthCause, rhs: HealthCause) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A problem to show in the panel's message area, with the figures its text needs.
public enum HealthMessage: Equatable, Sendable {
    case memory
    case disk(freeBytes: UInt64)
    case processes(count: Int, limit: Int)
    /// `windowMinutes` is the user's setting, not the span the average actually covered.
    case cpu(percent: Double, windowMinutes: Int)
    case thermal(ThermalLevel)

    public var cause: HealthCause {
        switch self {
        case .memory: .memory
        case .disk: .disk
        case .processes: .processes
        case .cpu: .cpu
        case .thermal: .thermal
        }
    }

    /// False only for disk, which has no culprit process to show.
    public var opensActivityMonitor: Bool {
        if case .disk = self { false } else { true }
    }
}

public struct HealthStatus: Equatable, Sendable {
    public var memory: CardState
    public var cpu: CardState
    public var disk: CardState
    public var processes: CardState
    /// At most one per cause, sorted by ``HealthCause``.
    public var messages: [HealthMessage]

    public init(memory: CardState, cpu: CardState, disk: CardState, processes: CardState,
                messages: [HealthMessage]) {
        self.memory = memory
        self.cpu = cpu
        self.disk = disk
        self.processes = processes
        self.messages = messages
    }
}

/// Turns readings and thresholds into card states and messages.
///
/// CPU, disk and processes turn red past their threshold and clear only once back past it by a
/// margin, so a reading sitting at the line does not flicker. The evaluator holds those red flags;
/// call it on one instance, in order. Thresholds are read from `settings` on every call, so a
/// change applies at once.
public struct HealthEvaluator: Sendable {
    static let cpuClearMarginPercent = 5.0
    static let diskClearMarginGB = 2
    static let processClearMarginPercent = 5.0
    private static let bytesPerGB = 1_000_000_000.0

    private var isCPURed = false
    private var isDiskRed = false
    private var isProcessesRed = false

    public init() {}

    public mutating func evaluate(_ readings: HealthReadings, settings: HealthSettings) -> HealthStatus {
        var messages: [HealthMessage] = []

        let memory = memoryState(readings.memory, settings: settings)
        if memory == .red { messages.append(.memory) }

        let cpu = cpuState(readings.cpu, settings: settings)
        if cpu == .red, case .full(let percent, _) = readings.cpu {
            messages.append(.cpu(percent: percent, windowMinutes: settings.cpuWindowMinutes))
        }

        let disk = diskState(readings.diskFreeBytes, settings: settings)
        if disk == .red, let free = readings.diskFreeBytes { messages.append(.disk(freeBytes: free)) }

        let processes = processesState(count: readings.processCount, limit: readings.processLimit, settings: settings)
        if processes == .red, let count = readings.processCount, let limit = readings.processLimit {
            messages.append(.processes(count: count, limit: limit))
        }

        if readings.thermal != .normal { messages.append(.thermal(readings.thermal)) }

        return HealthStatus(memory: memory, cpu: cpu, disk: disk, processes: processes,
                            messages: messages.sorted { $0.cause < $1.cause })
    }

    private func memoryState(_ level: MemoryLevel?, settings: HealthSettings) -> CardState {
        guard let level else { return .notKnown }
        if level >= settings.memoryRedLevel { return .red }
        return level == .warning ? .yellow : .green
    }

    private mutating func cpuState(_ average: CPUAverage, settings: HealthSettings) -> CardState {
        switch average {
        case .notKnown:
            isCPURed = false
            return .notKnown
        case .partial:
            isCPURed = false
            return .green
        case .full(let percent, _):
            let threshold = Double(settings.cpuPercent)
            isCPURed = percent > threshold || (isCPURed && percent > threshold - Self.cpuClearMarginPercent)
            return isCPURed ? .red : .green
        }
    }

    private mutating func diskState(_ freeBytes: UInt64?, settings: HealthSettings) -> CardState {
        guard let freeBytes else {
            isDiskRed = false
            return .notKnown
        }
        let free = Double(freeBytes)
        let threshold = Double(settings.diskFreeGB) * Self.bytesPerGB
        let clearAt = Double(settings.diskFreeGB + Self.diskClearMarginGB) * Self.bytesPerGB
        isDiskRed = free < threshold || (isDiskRed && free < clearAt)
        return isDiskRed ? .red : .green
    }

    private mutating func processesState(count: Int?, limit: Int?, settings: HealthSettings) -> CardState {
        guard let count, let limit else {
            isProcessesRed = false
            return .notKnown
        }
        let threshold = Double(limit) * Double(settings.processSharePercent) / 100
        let clearAt = threshold - Double(limit) * Self.processClearMarginPercent / 100
        isProcessesRed = Double(count) > threshold || (isProcessesRed && Double(count) > clearAt)
        return isProcessesRed ? .red : .green
    }
}
