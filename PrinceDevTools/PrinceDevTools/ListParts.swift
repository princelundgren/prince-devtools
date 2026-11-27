import AppKit
import SwiftUI

/// When a list scrolls, so the panel stays on screen.
enum ListScrolling {
    /// The most rows a list shows without scrolling.
    static let rowsBeforeScrolling = 12
    /// The height of a list that scrolls.
    static let height: CGFloat = 300
}

/// The insets that line a list's header and cells up with its rows.
enum ListInset {
    /// The side inset of a list's rows.
    static let row: CGFloat = 6
    /// How far a clickable cell's text sits inside its highlight.
    static let cell: CGFloat = 3
}

/// Puts `string` on the general pasteboard as plain text, in place of what was there.
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// A list's header: its title centred and Back at the leading edge, lined up with the rows' cells.
struct ListHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Button(action: back) {
                Label("Back", systemImage: "chevron.backward")
            }
            .buttonStyle(BackButtonStyle())
            .padding(.leading, ListInset.row + ListInset.cell)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 4)
    }
}

/// A table cell that does something when clicked: highlighted under the pointer, its help tag as
/// its VoiceOver label, and "Copied" in its place for a moment after a copy.
struct ActionCell<Label: View>: View {
    private static var confirmationTime: Duration { .seconds(1.2) }

    let help: String
    var isEnabled = true
    let confirms: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isConfirming = false
    /// Counts the copies, so each one restarts the confirmation's timer.
    @State private var copies = 0

    var body: some View {
        Button {
            action()
            if confirms {
                isConfirming = true
                copies += 1
            }
        } label: {
            ZStack(alignment: .leading) {
                label.opacity(isConfirming ? 0 : 1)
                if isConfirming {
                    Text("Copied").foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(HighlightButtonStyle())
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
        .task(id: copies) {
            guard isConfirming, (try? await Task.sleep(for: Self.confirmationTime)) != nil else { return }
            isConfirming = false
        }
    }
}

/// A plain button highlighted under the pointer and darker while pressed, with the pointing hand
/// while enabled: the table's cells.
struct HighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HighlightButton(configuration: configuration)
    }
}

private struct HighlightButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.vertical, 2)
            .padding(.horizontal, ListInset.cell)
            .background {
                if isEnabled && (isHovered || configuration.isPressed) {
                    RoundedRectangle(cornerRadius: 4).fill(configuration.isPressed ? .tertiary : .quaternary)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .pointerStyle(isEnabled ? .link : nil)
    }
}

/// The header's Back: secondary text that turns primary under the pointer and dims while pressed,
/// with no highlight behind it.
struct BackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BackButton(configuration: configuration)
    }
}

private struct BackButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovered ? .primary : .secondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
    }
}
