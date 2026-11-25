import AppKit
import PanelKit
import SwiftUI

/// Settings → About: the app's icon, name and version, with Check for Updates….
struct AboutPane: View {
    private static let iconSize: CGFloat = 64

    let updater: Updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PrinceDevTools")
                            .font(.title2.bold())
                        Text(version)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return versionText(
            marketingVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?")
    }
}
