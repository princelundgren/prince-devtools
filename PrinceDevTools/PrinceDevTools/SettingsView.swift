import SwiftUI
import SystemHealth

/// One pane of the Settings window's sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case systemHealth, general, about

    var id: Self { self }

    var title: String {
        switch self {
        case .systemHealth: "System health"
        case .general: "General"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .systemHealth: "gauge.with.dots.needle.67percent"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// The Settings window's content: a sidebar of panes beside the chosen pane, which is restored
/// the next time the window opens.
struct SettingsView: View {
    static let minimumSize = CGSize(width: 620, height: 540)
    static let idealSize = CGSize(width: 760, height: 640)
    /// The user defaults key of the pane shown.
    static let paneKey = "settingsPane"

    let monitor: HealthMonitor
    let updater: Updater
    @AppStorage(SettingsView.paneKey) private var pane: SettingsPane = .systemHealth

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: paneSelection) { pane in
                Label(pane.title, systemImage: pane.symbolName)
            }
        } detail: {
            switch pane {
            case .systemHealth: SystemHealthSettingsPane(monitor: monitor)
            case .general: GeneralSettingsPane()
            case .about: AboutPane(updater: updater)
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    /// The sidebar's selection, which can't be cleared, since a pane is always shown.
    private var paneSelection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { if let selected = $0 { pane = selected } })
    }
}
