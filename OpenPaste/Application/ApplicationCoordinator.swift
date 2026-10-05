import AppKit

@MainActor
final class ApplicationCoordinator {
    private let preferencesStore: any PreferencesStore
    private let captureService: ClipboardCaptureService
    private let shortcutService: GlobalShortcutService
    private let statusMenu = StatusMenuController()
    private var pillWindowController: FloatingPillWindowController?
    private var demoTask: Task<Void, Never>?

    init(
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore.shared,
        captureService: ClipboardCaptureService = ClipboardCaptureService(),
        shortcutService: GlobalShortcutService = GlobalShortcutService()
    ) {
        #if DEBUG
        if ClipboardDemoData.isEnabled, let defaults = UserDefaults(suiteName: "OpenPaste-UI-Tests") {
            defaults.removePersistentDomain(forName: "OpenPaste-UI-Tests")
            self.preferencesStore = UserDefaultsPreferencesStore(defaults: defaults)
        } else {
            self.preferencesStore = preferencesStore
        }
        #else
        self.preferencesStore = preferencesStore
        #endif
        self.captureService = captureService
        self.shortcutService = shortcutService
    }

    func start() {
        guard pillWindowController == nil else { return }
        #if DEBUG
        if ClipboardDemoData.isEnabled {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--appearance-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if arguments.contains("--appearance-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        }
        #endif
        pillWindowController = makePillWindowController()
        shortcutService.onActivate = { [weak self] in
            self?.pillWindowController?.toggle()
        }
        shortcutService.register(preferencesStore.preferences.activationShortcut)

        statusMenu.install(
            open: { [weak self] in self?.pillWindowController?.show() },
            pause: { [weak self] in self?.captureService.pause(for: $0) },
            resume: { [weak self] in self?.captureService.resume() },
            shortcutError: shortcutService.registrationError)
        pillWindowController?.show()
    }

    func stop() {
        demoTask?.cancel()
        demoTask = nil
        shortcutService.unregister()
        shortcutService.onActivate = nil
        captureService.stop()
        statusMenu.remove()
        pillWindowController?.dismiss(restoreFocus: false)
        pillWindowController = nil
    }

    private func makePillWindowController() -> FloatingPillWindowController {
        do {
            let repository: ClipboardRepository
            #if DEBUG
            if ClipboardDemoData.isEnabled {
                repository = try ClipboardDemoData.makeRepository()
                demoTask = Task {
                    do {
                        try await ClipboardDemoData.populate(repository)
                    } catch {
                        NSLog("OpenPaste UI fixture failed: %@", error.localizedDescription)
                    }
                }
            } else {
                repository = ClipboardRepository(database: try AppDatabase.openDefault())
                captureService.start(store: repository, preferencesStore: preferencesStore)
            }
            #else
            repository = ClipboardRepository(database: try AppDatabase.openDefault())
            captureService.start(store: repository, preferencesStore: preferencesStore)
            #endif
            return FloatingPillWindowController(
                clipboardStore: repository,
                preferencesStore: preferencesStore,
                onPause: { [weak self] in self?.captureService.pause(for: $0) },
                onResume: { [weak self] in self?.captureService.resume() },
                onPasteboardWrite: { [weak self] in self?.captureService.ignorePasteboardChangeCount($0) })
        } catch {
            return FloatingPillWindowController(
                clipboardStore: nil,
                preferencesStore: preferencesStore,
                startupError: error.localizedDescription)
        }
    }
}
