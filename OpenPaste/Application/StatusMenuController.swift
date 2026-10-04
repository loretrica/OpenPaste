import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var onOpen: (() -> Void)?
    private var onPause: ((CapturePauseDuration) -> Void)?
    private var onResume: (() -> Void)?

    func install(
        open: @escaping () -> Void,
        pause: @escaping (CapturePauseDuration) -> Void,
        resume: @escaping () -> Void,
        shortcutError: Int32?
    ) {
        remove()
        onOpen = open
        onPause = pause
        onResume = resume

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "OpenPaste")
        item.button?.toolTip = "OpenPaste"
        item.menu = makeMenu(shortcutError: shortcutError)
        statusItem = item
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        onOpen = nil
        onPause = nil
        onResume = nil
    }

    private func makeMenu(shortcutError: Int32?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("Apri OpenPaste", action: #selector(openPill)))
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(title: "Metti in pausa la raccolta", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        pauseMenu.addItem(makeItem("15 minuti", action: #selector(pauseForFifteenMinutes)))
        pauseMenu.addItem(makeItem("1 ora", action: #selector(pauseForOneHour)))
        pauseMenu.addItem(makeItem("Fino alla ripresa manuale", action: #selector(pauseUntilResumed)))
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)
        menu.addItem(makeItem("Riprendi la raccolta", action: #selector(resumeCapture)))

        if let shortcutError {
            menu.addItem(.separator())
            let status = NSMenuItem(
                title: "Scorciatoia non disponibile (\(shortcutError))",
                action: nil,
                keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Esci da OpenPaste", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func openPill() { onOpen?() }
    @objc private func pauseForFifteenMinutes() { onPause?(.fifteenMinutes) }
    @objc private func pauseForOneHour() { onPause?(.oneHour) }
    @objc private func pauseUntilResumed() { onPause?(.untilResumed) }
    @objc private func resumeCapture() { onResume?() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
