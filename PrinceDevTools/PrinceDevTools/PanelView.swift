import AppKit
import PanelKit
import SwiftUI
import SystemHealth

/// The menu bar panel: the messages, the system health cards and the footer.
struct PanelView: View {
    private static let width: CGFloat = 320
    private static let cardSpacing: CGFloat = 8

    let monitor: HealthMonitor
    let updater: Updater
    let openSettings: () -> Void

    var body: some View {
        let cards = HealthText.cards(
            monitor.readings, monitor.status, windowMinutes: monitor.settings.cpuWindowMinutes, locale: .current)
        VStack(alignment: .leading, spacing: 10) {
            MessageArea(messages: panelMessages(monitor, locale: .current), openActivityMonitor: ActivityMonitor.open)
            CardGrid(spacing: Self.cardSpacing) {
                ForEach(cards, id: \.title) { card in
                    CardView(
                        title: card.title, tone: panelTone(card.state), value: card.value, detail: card.detail,
                        gauge: card.gauge, accessibilityLabel: card.accessibilityLabel)
                }
            }
            PanelFooter(
                updateVersion: updater.updateVersion, viewUpdate: updater.checkForUpdates,
                openSettings: openSettings, quit: { NSApplication.shared.terminate(nil) })
        }
        .padding()
        .frame(width: Self.width)
    }
}
