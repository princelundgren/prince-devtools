import AppKit
import LocalServers
import PanelKit
import SwiftUI
import SystemHealth

/// The menu bar panel: the messages, the system health cards and the Servers card, or the server
/// list in their place; and the footer.
struct PanelView: View {
    private static let width: CGFloat = 320
    /// The server list's table needs more room than the cards.
    private static let listWidth: CGFloat = 520
    private static let cardSpacing: CGFloat = 8

    let monitor: HealthMonitor
    let servers: ServerMonitor
    let updater: Updater
    let openSettings: () -> Void

    var body: some View {
        let cards = HealthText.cards(
            monitor.readings, monitor.status, windowMinutes: monitor.settings.cpuWindowMinutes, locale: .current)
        VStack(alignment: .leading, spacing: 10) {
            if servers.isListShown {
                ServerListView(monitor: servers)
            } else {
                MessageArea(
                    messages: panelMessages(monitor, locale: .current), openActivityMonitor: ActivityMonitor.open)
                CardGrid(spacing: Self.cardSpacing) {
                    ForEach(cards, id: \.title) { card in
                        CardView(
                            title: card.title, tone: panelTone(card.state), value: card.value, detail: card.detail,
                            gauge: card.gauge, accessibilityLabel: card.accessibilityLabel)
                    }
                    serverCard
                }
            }
            PanelFooter(
                updateVersion: updater.updateVersion, viewUpdate: updater.checkForUpdates,
                openSettings: openSettings, quit: { NSApplication.shared.terminate(nil) })
        }
        .padding()
        .frame(width: servers.isListShown ? Self.listWidth : Self.width)
    }

    private var serverCard: some View {
        let card = ServerText.card(servers.scan?.servers, locale: .current)
        return CardView(
            title: ServerText.title, tone: servers.scan == nil ? .notKnown : .info, value: card.value,
            detail: card.detail, gauge: nil, accessibilityLabel: card.accessibilityLabel,
            action: CardAction(accessibilityHint: "Opens the server list", perform: servers.showList))
    }
}
