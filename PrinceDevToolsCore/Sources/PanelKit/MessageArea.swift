import SwiftUI

/// One problem in the message area; `id` names its cause.
public struct PanelMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let detail: String?
    public let opensActivityMonitor: Bool

    public init(id: String, text: String, detail: String?, opensActivityMonitor: Bool) {
        self.id = id
        self.text = text
        self.detail = detail
        self.opensActivityMonitor = opensActivityMonitor
    }
}

/// The problems at the top of the panel, in the order given; nothing while there are none.
public struct MessageArea: View {
    private let messages: [PanelMessage]
    private let openActivityMonitor: () -> Void

    public init(messages: [PanelMessage], openActivityMonitor: @escaping () -> Void) {
        self.messages = messages
        self.openActivityMonitor = openActivityMonitor
    }

    public var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages) { message in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.text)
                            if let detail = message.detail {
                                Text(detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: attentionSymbolName)
                            .foregroundStyle(PanelTone.red.color)
                    }
                    .accessibilityElement(children: .combine)
                }
                if messages.contains(where: \.opensActivityMonitor) {
                    Button("Open Activity Monitor", action: openActivityMonitor)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider()
            }
            .font(.callout)
        }
    }
}
