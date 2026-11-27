import Foundation

/// The Containers card's strings.
public struct ContainerCard: Equatable, Sendable {
    public let value: String
    public let detail: String?
    /// "Containers, <value>[, <detail>]".
    public let accessibilityLabel: String
}

/// One row's strings.
public struct ContainerRowText: Equatable, Sendable {
    public let name: String
    /// The image without its digest, as `docker ps` shows it: `prom/prometheus:v3.16.0`.
    public let image: String
    /// The image as the engine names it, digest included, for copying.
    public let imageReference: String
    /// The image cell's help tag and VoiceOver label: "Copy nginx:latest", with "with its digest"
    /// when the copy holds one, so VoiceOver never reads out its 64 hex digits.
    public let copyImage: String
    public let runtime: String
    /// "59 min", "10 h", "3 d", rounded down.
    public let up: String
    /// `up` in words ("3 hours"), for its cell's VoiceOver label, since VoiceOver reads "h" as a
    /// letter.
    public let spokenUp: String
    /// The container's memory, or "—" when it is unknown.
    public let memory: String
    /// `memory` for VoiceOver: "memory unknown" in place of "—", which it reads as a dash or not at all.
    public let spokenMemory: String
    /// The row's help tag and VoiceOver label: name, image, runtime, time up in words ("3 hours")
    /// and memory in words.
    public let description: String
}

/// The containers tool's wording. Counts and memory are formatted for `locale`; the words are English.
public enum ContainerText {
    public static let title = "Containers"
    private static let noContainers = "No containers running"
    private static let unknownMemory = "—"
    private static let spokenUnknownMemory = "memory unknown"

    /// The card for a scan; `nil` before the first scan. The detail is the memory total of the
    /// containers whose memory is known, then the number of runtimes that couldn't be read.
    public static func card(_ scan: ContainerScan?, locale: Locale) -> ContainerCard {
        guard let scan else { return card(value: "Not known yet", detail: nil) }
        if nothingCouldBeRead(scan) { return card(value: "Can't read", detail: nil) }
        let count = scan.containers.count
        let value = count == 0 ? "None running" : "\(integer(count, locale: locale)) running"
        let known = scan.containers.compactMap(\.memoryBytes)
        let total = known.isEmpty ? nil : memory(saturatingSum(known), locale: locale)
        let unreadable = scan.unreadableRuntimes.count
        let unreadableDetail = unreadable == 0
            ? nil : "\(integer(unreadable, locale: locale)) \(unreadable == 1 ? "runtime" : "runtimes") unreadable"
        let detail = [total, unreadableDetail].compactMap { $0 }.joined(separator: ", ")
        return card(value: value, detail: detail.isEmpty ? nil : detail)
    }

    /// The row for `container`, its time up counted to `now`.
    public static func row(_ container: Container, now: Date, locale: Locale) -> ContainerRowText {
        let (up, spokenUp) = up(since: container.created, now: now, locale: locale)
        let known = container.memoryBytes.map { Self.memory($0, locale: locale) }
        let spokenMemory = known ?? spokenUnknownMemory
        let image = withoutDigest(container.image)
        let copyImage = image == container.image ? "Copy \(image)" : "Copy \(image) with its digest"
        let description = [container.name, image, container.runtime, "up \(spokenUp)", spokenMemory]
            .joined(separator: ", ")
        return ContainerRowText(
            name: container.name, image: image, imageReference: container.image, copyImage: copyImage,
            runtime: container.runtime, up: up, spokenUp: spokenUp, memory: known ?? unknownMemory,
            spokenMemory: spokenMemory, description: description)
    }

    /// "No containers running" for an empty scan, or `nil` when no runtime was read and one
    /// couldn't be, where only the unreadable lines show.
    public static func emptyList(_ scan: ContainerScan) -> String? {
        nothingCouldBeRead(scan) ? nil : noContainers
    }

    /// The line naming a runtime that couldn't be read.
    public static func unreadable(_ runtime: String) -> String {
        "Couldn't read \(runtime)"
    }

    /// No runtime was read and at least one couldn't be: the card says "Can't read".
    private static func nothingCouldBeRead(_ scan: ContainerScan) -> Bool {
        scan.runtimesRead.isEmpty && !scan.unreadableRuntimes.isEmpty
    }

    private static func card(value: String, detail: String?) -> ContainerCard {
        ContainerCard(
            value: value, detail: detail,
            accessibilityLabel: ([title, value] + [detail].compactMap { $0 }).joined(separator: ", "))
    }

    /// "3 h" to show and "3 hours" to speak, since VoiceOver reads "h" as a letter.
    private static func up(since start: Date, now: Date, locale: Locale) -> (shown: String, spoken: String) {
        let seconds = now.timeIntervalSince(start)
        let minutes = seconds > 0 ? Int(min(seconds / 60, Double(Int32.max))) : 0
        let (count, symbol, unit) = minutes < 60 ? (minutes, "min", "minute")
            : minutes < 24 * 60 ? (minutes / 60, "h", "hour") : (minutes / (24 * 60), "d", "day")
        let number = integer(count, locale: locale)
        return ("\(number) \(symbol)", "\(number) \(unit)\(count == 1 ? "" : "s")")
    }

    /// `name[:tag]@digest` without `@digest`; an image ID, which has no `@`, as it is.
    private static func withoutDigest(_ image: String) -> String {
        guard let at = image.firstIndex(of: "@"), at > image.startIndex else { return image }
        return String(image[..<at])
    }

    private static func saturatingSum(_ bytes: [UInt64]) -> UInt64 {
        bytes.reduce(0) { sum, next in
            let (total, overflow) = sum.addingReportingOverflow(next)
            return overflow ? .max : total
        }
    }

    /// The style formats an `Int64`, so a larger figure shows as `Int64.max`.
    private static func memory(_ bytes: UInt64, locale: Locale) -> String {
        Int64(clamping: bytes).formatted(ByteCountFormatStyle(style: .memory, locale: locale))
    }

    private static func integer(_ number: Int, locale: Locale) -> String {
        number.formatted(.number.locale(locale))
    }
}
