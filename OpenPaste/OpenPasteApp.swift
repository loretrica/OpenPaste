import AppKit
import Foundation

@main
struct OpenPasteApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = OpenPasteAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class OpenPasteAppDelegate: NSObject, NSApplicationDelegate {
    private let preferencesStore = UserDefaultsPreferencesStore.shared
    private let shortcutService = GlobalShortcutService()
    private var clipboardStore: ClipboardRepository?
    private var pillWindowController: FloatingPillWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let database = try AppDatabase.openDefault()
            let repository = ClipboardRepository(database: database)
            clipboardStore = repository
            ClipboardCaptureService.shared.start(
                store: repository,
                preferencesStore: preferencesStore)
            pillWindowController = FloatingPillWindowController(
                clipboardStore: repository,
                preferencesStore: preferencesStore)
        } catch {
            pillWindowController = FloatingPillWindowController(
                clipboardStore: nil,
                preferencesStore: preferencesStore,
                startupError: error.localizedDescription)
        }

        shortcutService.onActivate = { [weak self] in
            self?.pillWindowController?.toggle()
        }
        shortcutService.register(preferencesStore.preferences.activationShortcut)
        installStatusItem()
        pillWindowController?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutService.unregister()
        ClipboardCaptureService.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openPill() {
        pillWindowController?.show()
    }

    @objc private func pauseForFifteenMinutes() {
        ClipboardCaptureService.shared.pause(for: .fifteenMinutes)
    }

    @objc private func pauseForOneHour() {
        ClipboardCaptureService.shared.pause(for: .oneHour)
    }

    @objc private func pauseUntilResumed() {
        ClipboardCaptureService.shared.pause(for: .untilResumed)
    }

    @objc private func resumeCapture() {
        ClipboardCaptureService.shared.resume()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "OpenPaste")
        item.button?.toolTip = "OpenPaste"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Apri OpenPaste", action: #selector(openPill), keyEquivalent: ""))
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(title: "Metti in pausa la raccolta", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        pauseMenu.addItem(NSMenuItem(
            title: "15 minuti",
            action: #selector(pauseForFifteenMinutes),
            keyEquivalent: ""))
        pauseMenu.addItem(NSMenuItem(
            title: "1 ora",
            action: #selector(pauseForOneHour),
            keyEquivalent: ""))
        pauseMenu.addItem(NSMenuItem(
            title: "Fino alla ripresa manuale",
            action: #selector(pauseUntilResumed),
            keyEquivalent: ""))
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem(
            title: "Riprendi la raccolta",
            action: #selector(resumeCapture),
            keyEquivalent: ""))

        if let status = shortcutService.registrationError {
            menu.addItem(.separator())
            let shortcutStatus = NSMenuItem(
                title: "Scorciatoia non disponibile (\(status))",
                action: nil,
                keyEquivalent: "")
            shortcutStatus.isEnabled = false
            menu.addItem(shortcutStatus)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Esci da OpenPaste", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { item in
            item.target = self
            item.submenu?.items.forEach { $0.target = self }
        }
        item.menu = menu
        statusItem = item
    }
}
