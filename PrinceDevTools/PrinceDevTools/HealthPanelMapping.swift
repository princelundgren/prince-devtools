import Foundation
import PanelKit
import SystemHealth

/// The monitor's messages as the panel shows them, each with its culprit's line once one is found.
@MainActor
func panelMessages(_ monitor: HealthMonitor, locale: Locale) -> [PanelMessage] {
    monitor.status.messages.map { message in
        PanelMessage(
            id: String(describing: message.cause),
            text: HealthText.message(message, locale: locale),
            detail: monitor.culprits[message.cause].map { HealthText.culprit($0, locale: locale) },
            opensActivityMonitor: message.opensActivityMonitor)
    }
}

func panelTone(_ state: CardState) -> PanelTone {
    switch state {
    case .notKnown: .notKnown
    case .green: .green
    case .yellow: .yellow
    case .red: .red
    }
}
