import SwiftUI

/// One metric's card: title, a status symbol and value, an optional detail line and an optional
/// gauge. VoiceOver reads it as one element, `accessibilityLabel`.
public struct CardView: View {
    private let title: String
    private let tone: PanelTone
    private let value: String
    private let detail: String?
    private let gauge: Double?
    private let accessibilityLabel: String
    @Environment(\.colorScheme) private var colorScheme

    /// `gauge` is the share used, 0 through 1; the progress view pins a value outside that.
    public init(
        title: String, tone: PanelTone, value: String, detail: String?, gauge: Double?,
        accessibilityLabel: String
    ) {
        self.title = title
        self.tone = tone
        self.value = value
        self.detail = detail
        self.gauge = gauge
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(fill, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var fill: AnyShapeStyle {
        tone == .notKnown ? AnyShapeStyle(.quinary) : AnyShapeStyle(tone.color.opacity(0.1))
    }

    /// `.secondary` falls to about 3.7:1 on a light-appearance tint, so text there is `.primary`.
    private var secondaryText: Color {
        colorScheme == .light && tone != .notKnown ? .primary : .secondary
    }
}
