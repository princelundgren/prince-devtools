import SwiftUI

/// The Settings window's content.
struct SettingsView: View {
    static let minimumSize = CGSize(width: 620, height: 540)
    static let idealSize = CGSize(width: 760, height: 640)

    var body: some View {
        Color.clear
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }
}
