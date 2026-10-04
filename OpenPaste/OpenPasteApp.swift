import AppKit

@main
struct OpenPasteApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = OpenPasteAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class OpenPasteAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = ApplicationCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
