import SwiftUI

/// One metric's card: title, a status symbol and value, an optional detail line and an optional
/// gauge. It fills the size it is offered, its lines at the top. VoiceOver reads it as one
/// element, `accessibilityLabel`; with an action it is a button, with the action's hint.
public struct CardView: View {
    private let title: String
    private let tone: PanelTone
    private let value: String
    private let detail: String?
    private let gauge: Double?
    private let accessibilityLabel: String
    private let action: CardAction?
    @Environment(\.colorScheme) private var colorScheme

    /// `gauge` is the share used, 0 through 1; the progress view pins a value outside that. A
    /// non-nil `action` makes the whole card a button that runs it, looking and sizing as before.
    public init(
        title: String, tone: PanelTone, value: String, detail: String?, gauge: Double?,
        accessibilityLabel: String, action: CardAction? = nil
    ) {
        self.title = title
        self.tone = tone
        self.value = value
        self.detail = detail
        self.gauge = gauge
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action.perform) { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(action.accessibilityHint)
                .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(secondaryText)
            Label {
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
            } icon: {
                Image(systemName: tone.symbolName)
                    .foregroundStyle(tone.color)
            }
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
            if let gauge {
                ProgressView(value: gauge)
                    .tint(tone.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(fill, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var fill: AnyShapeStyle {
        tone == .notKnown ? AnyShapeStyle(.quinary) : AnyShapeStyle(tone.color.opacity(0.1))
    }

    /// `.secondary` falls to about 3.7:1 on a light-appearance tint, so text there is `.primary`.
    private var secondaryText: Color {
        colorScheme == .light && tone != .notKnown ? .primary : .secondary
    }
}

/// What a card does when clicked, and how VoiceOver describes it.
public struct CardAction {
    let accessibilityHint: String
    let perform: @MainActor () -> Void

    /// `accessibilityHint` says what the click does, in words that follow the card's label.
    public init(accessibilityHint: String, perform: @escaping @MainActor () -> Void) {
        self.accessibilityHint = accessibilityHint
        self.perform = perform
    }
}
