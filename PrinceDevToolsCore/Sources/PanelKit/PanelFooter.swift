import SwiftUI

/// The panel's foot: the update row while an update is ready, then Settings on the left and Quit
/// on the right.
public struct PanelFooter: View {
    private let updateVersion: String?
    private let viewUpdate: () -> Void
    private let openSettings: () -> Void
    private let quit: () -> Void

    public init(
        updateVersion: String?, viewUpdate: @escaping () -> Void, openSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.updateVersion = updateVersion
        self.viewUpdate = viewUpdate
        self.openSettings = openSettings
        self.quit = quit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let updateVersion {
                Divider()
                HStack {
                    Text("Version \(updateVersion) is ready")
                    Spacer()
                    Button("View…", action: viewUpdate)
                }
            }
            Divider()
            HStack {
                FooterIconButton(title: "Settings…", systemImage: "gear", action: openSettings)
                Spacer()
                FooterIconButton(title: "Quit PrinceDevTools", systemImage: "power", action: quit)
            }
        }
    }
}

/// A plain secondary symbol whose whole 30 pt square takes the click, with its title as the
/// VoiceOver label and help tag.
private struct FooterIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel(title)
        .help(title)
    }
}
