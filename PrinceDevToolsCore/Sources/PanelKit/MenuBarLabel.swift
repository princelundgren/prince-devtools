/// The symbol of the status item while a message is up, and of each message.
let attentionSymbolName = "exclamationmark.triangle.fill"

/// What the status item shows: a different symbol, not only a colour, while any message is up.
public struct MenuBarLabel: Equatable, Sendable {
    public let symbolName: String
    public let isAttention: Bool
    public let accessibilityLabel: String
}

/// The status item for the panel's `messages`; its accessibility label names the first one.
public func menuBarLabel(messages: [PanelMessage]) -> MenuBarLabel {
    guard let first = messages.first else {
        return MenuBarLabel(
            symbolName: "gauge.with.dots.needle.33percent", isAttention: false,
            accessibilityLabel: "PrinceDevTools")
    }
    return MenuBarLabel(
        symbolName: attentionSymbolName, isAttention: true,
        accessibilityLabel: "PrinceDevTools: \(first.text)")
}
