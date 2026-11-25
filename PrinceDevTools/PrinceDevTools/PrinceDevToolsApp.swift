import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {}

@main
@MainActor
enum PrinceDevToolsApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
