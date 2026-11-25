import Foundation

/// One card of the panel, with every string it shows.
public struct HealthCard: Equatable, Sendable {
    public let title: String
    public let state: CardState
    public let value: String
    public let detail: String?
    /// 0...1 fill for a card shown as a gauge; `nil` for cards without one.
    public let gauge: Double?
    /// The one place the state is spoken: "<title>, <value>[, <detail>], <state>". The state word is
    /// left out when the value already is that word (memory) and for a card that is not known yet.
    public let accessibilityLabel: String

    public init(title: String, state: CardState, value: String, detail: String? = nil, gauge: Double? = nil) {
        self.title = title
        self.state = state
        self.value = value
        self.detail = detail
        self.gauge = gauge
        self.accessibilityLabel = Self.spokenLabel(title: title, state: state, value: value, detail: detail)
    }

    private static func spokenLabel(title: String, state: CardState, value: String, detail: String?) -> String {
        let stateWord: String
        switch state {
        case .notKnown: return "\(title), \(value)"
        case .green: stateWord = "green"
        case .yellow: stateWord = "yellow"
        case .red: stateWord = "red"
        }
        let spokenState = value.lowercased() == stateWord ? [] : [stateWord]
        return ([title, value] + [detail].compactMap { $0 } + spokenState).joined(separator: ", ")
    }
}

/// The panel's wording. Numbers are formatted for `locale`; the words are English.
public enum HealthText {
    private static let notKnownValue = "Not known yet"

    /// The Memory, CPU, Disk and Processes cards, in that order.
    ///
    /// `windowMinutes` is the user's CPU window; a partial average words the span it covers so far.
    public static func cards(
        _ readings: HealthReadings, _ status: HealthStatus, windowMinutes: Int, locale: Locale
    ) -> [HealthCard] {
        [
            memoryCard(readings, state: status.memory, locale: locale),
            cpuCard(readings.cpu, state: status.cpu, windowMinutes: windowMinutes, locale: locale),
            diskCard(readings.diskFreeBytes, state: status.disk, locale: locale),
            processesCard(count: readings.processCount, limit: readings.processLimit,
                          state: status.processes, locale: locale),
        ]
    }

    /// The line shown for a problem in the panel's message area.
    public static func message(_ message: HealthMessage, locale: Locale) -> String {
        switch message {
        case .memory:
            "Memory pressure is red"
        case .disk(let freeBytes):
            "\(fileSize(freeBytes, locale: locale)) free on the startup disk"
        case .processes(let count, let limit):
            "\(integer(count, locale: locale)) of \(integer(limit, locale: locale)) processes in use"
        case .cpu(let percent, let windowMinutes):
            "CPU avg \(windowMinutes) min is \(percentage(percent, locale: locale))"
        case .thermal(.serious):
            "Mac is running hot"
        case .thermal(.critical):
            "Mac is slowing down from heat"
        }
    }

    /// The line naming the process behind a message.
    public static func culprit(_ culprit: Culprit, locale: Locale) -> String {
        let prefix = "Top of your processes:"
        switch culprit {
        case .memory(let name, let bytes):
            return "\(prefix) \(name) \(memorySize(bytes, locale: locale))"
        case .cpu(let name, let percentOfCore):
            return "\(prefix) \(name) \(percentage(percentOfCore, locale: locale))"
        case .processes(let name, let count):
            return "\(prefix) \(name) × \(integer(count, locale: locale))"
        case .mostlySystem:
            return "Mostly system processes"
        }
    }

    private static func memoryCard(_ readings: HealthReadings, state: CardState, locale: Locale) -> HealthCard {
        guard state != .notKnown else { return notKnownCard("Memory") }
        let swap = readings.swapUsedBytes.map { "Swap \(memorySize($0, locale: locale))" }
        return HealthCard(title: "Memory", state: state, value: colourWord(state), detail: swap)
    }

    private static func cpuCard(
        _ average: CPUAverage, state: CardState, windowMinutes: Int, locale: Locale
    ) -> HealthCard {
        let percent: Double
        let minutes: Int
        switch average {
        case .notKnown:
            return notKnownCard("CPU")
        case .partial(let partialPercent, let span):
            percent = partialPercent
            minutes = max(1, Int((Double(span.components.seconds) / 60).rounded()))
        case .full(let fullPercent, _):
            percent = fullPercent
            minutes = windowMinutes
        }
        return HealthCard(title: "CPU", state: state, value: percentage(percent, locale: locale),
                          detail: "avg \(minutes) min")
    }

    private static func diskCard(_ freeBytes: UInt64?, state: CardState, locale: Locale) -> HealthCard {
        guard let freeBytes else { return notKnownCard("Disk") }
        return HealthCard(title: "Disk", state: state, value: "\(fileSize(freeBytes, locale: locale)) free")
    }

    private static func processesCard(
        count: Int?, limit: Int?, state: CardState, locale: Locale
    ) -> HealthCard {
        guard let count, let limit, limit > 0 else { return notKnownCard("Processes") }
        let value = "\(integer(count, locale: locale))/\(integer(limit, locale: locale))"
        return HealthCard(title: "Processes", state: state, value: value,
                          gauge: min(max(Double(count) / Double(limit), 0), 1))
    }

    private static func notKnownCard(_ title: String) -> HealthCard {
        HealthCard(title: title, state: .notKnown, value: notKnownValue)
    }

    private static func colourWord(_ state: CardState) -> String {
        switch state {
        case .green: "Green"
        case .yellow: "Yellow"
        case .red: "Red"
        case .notKnown: notKnownValue
        }
    }

    private static func fileSize(_ bytes: UInt64, locale: Locale) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    private static func memorySize(_ bytes: UInt64, locale: Locale) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory).locale(locale))
    }

    private static func integer(_ number: Int, locale: Locale) -> String {
        number.formatted(.number.locale(locale))
    }

    private static func percentage(_ percent: Double, locale: Locale) -> String {
        "\(percent.formatted(.number.precision(.fractionLength(0)).locale(locale))) %"
    }
}
