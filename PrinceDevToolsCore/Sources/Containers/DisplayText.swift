/// Text from another process or the disk, made safe to show and copy.
enum DisplayText {
    static let maxBytes = 1_024

    /// `text` with every control (`Cc`), line separator (`Zl`), paragraph separator (`Zp`) and
    /// `Bidi_Control` scalar replaced by U+FFFD, and cut at the last character that ends within
    /// ``maxBytes`` UTF-8 bytes.
    static func sanitized(_ text: String) -> String {
        var safe = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let isUnsafe = switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: true
            default: scalar.properties.isBidiControl
            }
            safe.append(isUnsafe ? "\u{FFFD}" : scalar)
        }
        var cut = ""
        var bytes = 0
        for character in String(safe) {
            bytes += character.utf8.count
            guard bytes <= maxBytes else { break }
            cut.append(character)
        }
        return cut
    }
}
