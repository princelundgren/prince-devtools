import AppKit
import Observation
import PanelKit
import SystemHealth

/// The menu bar item: a template symbol, or a red attention symbol while the panel has a message,
/// updated whenever the label changes. A click toggles the panel.
@MainActor
final class StatusItemController: NSObject {
    /// The menu bar font's 13 pt draws symbols smaller than many menu bar icons.
    private static let symbolPointSize: CGFloat = 16

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let togglePanel: () -> Void
    private var shownLabel: MenuBarLabel?

    var button: NSStatusBarButton? { statusItem.button }

    /// Puts the item back in the menu bar if it isn't shown there.
    func makeVisible() {
        statusItem.isVisible = true
    }

    init(monitor: HealthMonitor, togglePanel: @escaping () -> Void) {
        self.togglePanel = togglePanel
        super.init()
        statusItem.behavior = .terminationOnRemoval
        // Shown at every launch, so opening the app again after its item was removed brings it back.
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked)
        statusItem.button?.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.symbolPointSize, weight: .regular)
        Task { [weak self] in
            let labels = Observations { menuBarLabel(messages: panelMessages(monitor, locale: .current)) }
            for await label in labels {
                self?.show(label)
            }
        }
    }

    @objc private func buttonClicked() {
        togglePanel()
    }

    /// `Observations` yields after every reading, most often with the label unchanged.
    private func show(_ label: MenuBarLabel) {
        guard label != shownLabel, let button = statusItem.button else { return }
        shownLabel = label
        button.image = Self.image(for: label)
        button.setAccessibilityLabel(label.accessibilityLabel)
    }

    /// The normal symbol is a template, which the menu bar tints; the attention symbol is drawn in
    /// red, so it isn't one, since a button's `contentTintColor` tints only template images. A
    /// palette colours each layer in turn, and red alone would fill the exclamation mark too.
    private static func image(for label: MenuBarLabel) -> NSImage? {
        let symbol = NSImage(systemSymbolName: label.symbolName, accessibilityDescription: nil)
        guard label.isAttention else { return symbol }
        let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        image?.isTemplate = false
        return image
    }
}
