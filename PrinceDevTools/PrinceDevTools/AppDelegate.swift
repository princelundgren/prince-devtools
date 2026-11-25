import AppKit
import SwiftUI
import SystemHealth

/// Owns the app's AppKit side: the health monitor and the system events it follows, the status
/// item, the panel's popover, the Settings window and the hidden main menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let settingsFrameName = "Settings"

    private let monitor: HealthMonitor
    private let updater: Updater
    private let popover = NSPopover()
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    /// While the panel is shown: closes it on a click in another app, the desktop or another menu
    /// bar item.
    private var outsideClickMonitor: Any?
    private var systemPowerObserver: SystemPowerObserver?

    override init() {
        monitor = HealthMonitor()
        updater = Updater()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = StatusItemController(monitor: monitor, togglePanel: { [weak self] in self?.togglePanel() })
        setUpPopover()
        observeSleepAndWake()
        monitor.start()
    }

    /// Opening the app again while it runs, from Finder or Applications, puts its item back in the
    /// menu bar if it isn't there and opens the panel under it, in place of AppKit's default handling.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItem?.makeVisible()
        showPanel()
        return false
    }

    private func observeSleepAndWake() {
        let observer = SystemPowerObserver(
            willSleep: { [weak self] in self?.monitor.sleep() },
            didWake: { [weak self] in self?.monitor.wake() })
        observer.start()
        systemPowerObserver = observer
    }

    /// The menu bar an `LSUIElement` app never shows, there so its key equivalents work while the
    /// app is active: Settings… and Quit, and the Close and Edit commands Settings' fields need.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(settingsChosen), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit PrinceDevTools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    @objc private func settingsChosen() {
        showSettings()
    }

    private func setUpPopover() {
        popover.behavior = .transient
        let panel = PanelView(monitor: monitor, updater: updater, openSettings: { [weak self] in self?.showSettings() })
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.delegate = self
    }

    func popoverWillShow(_ notification: Notification) {
        monitor.panelOpened()
    }

    /// Every close passes here: a click outside, the icon and Settings alike.
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        monitor.panelClosed()
    }

    private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.popover.performClose(nil) }
            }
        }
    }

    /// Keeps the panel open through the mouse-down of a click on the status item, which a
    /// transient popover would take as a click outside; the click's mouse-up then closes it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              let button = statusItem?.button, event.window == button.window
        else { return true }
        return false
    }

    /// Shows the Settings window in front of other apps: the open one if it is open, else a new
    /// one, where and at the size the user last left it, else centred at its ideal size.
    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(monitor: monitor, updater: updater))
            // Only the minimum, so the window stays resizable and zoomable above it.
            hosting.sizingOptions = .minSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "PrinceDevTools Settings"
            window.setContentSize(SettingsView.idealSize)
            if !window.setFrameUsingName(Self.settingsFrameName) { window.center() }
            window.setFrameAutosaveName(Self.settingsFrameName)
            window.delegate = self
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Lets go of the closing Settings window, and of its autosave name, which the next window
    /// takes, before anything can bring this one forward again.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.setFrameAutosaveName("")
        settingsWindow = nil
    }
}
