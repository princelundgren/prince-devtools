import AppKit
import PanelKit
import SwiftUI

/// Settings → General: Launch at login.
/// The login item's status is read again when the pane appears and when the app becomes active,
/// since the user can change it in System Settings.
struct GeneralSettingsPane: View {
    @State private var status = LaunchAtLoginStatus.off
    @State private var failure: LaunchAtLoginFailure?

    var body: some View {
        let launchAtLogin = launchAtLoginSetting(status: status, failure: failure)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: launchAtLoginBinding(isOn: launchAtLogin.isOn))
                    SettingsNote("PrinceDevTools opens automatically when you log in to your Mac.")
                    switch launchAtLogin.note {
                    case .needsApproval(let note):
                        HStack {
                            SettingsNote(note)
                            Spacer()
                            Button("Open…", action: LaunchAtLogin.openLoginItemsSettings)
                                .controlSize(.small)
                        }
                    case .failed(let note):
                        SettingsNote(note)
                    case nil:
                        EmptyView()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { status = LaunchAtLogin.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = LaunchAtLogin.status
        }
    }

    /// Reads the system's answer back after each change, since registering can need the user's
    /// approval in System Settings.
    private func launchAtLoginBinding(isOn: Bool) -> Binding<Bool> {
        Binding(
            get: { isOn },
            set: { enabled in
                do {
                    try LaunchAtLogin.setEnabled(enabled)
                    failure = nil
                } catch {
                    failure = LaunchAtLoginFailure(turningOn: enabled, reason: error.localizedDescription)
                }
                status = LaunchAtLogin.status
            })
    }
}
