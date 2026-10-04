import AppKit

@MainActor
final class ApplicationCoordinator {
    private let preferencesStore: any PreferencesStore
    private let captureService: ClipboardCaptureService
    private let shortcutService: GlobalShortcutService
    private let statusMenu = StatusMenuController()
    private var pillWindowController: FloatingPillWindowController?

    init(
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore.shared,
        captureService: ClipboardCaptureService = ClipboardCaptureService(),
        shortcutService: GlobalShortcutService = GlobalShortcutService()
    ) {
        self.preferencesStore = preferencesStore
        self.captureService = captureService
        self.shortcutService = shortcutService
    }

    func start() {
        guard pillWindowController == nil else { return }
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
        shortcutService.unregister()
        shortcutService.onActivate = nil
        captureService.stop()
        statusMenu.remove()
        pillWindowController?.dismiss(restoreFocus: false)
        pillWindowController = nil
    }

    private func makePillWindowController() -> FloatingPillWindowController {
        do {
            let database = try AppDatabase.openDefault()
            let repository = ClipboardRepository(database: database)
            captureService.start(store: repository, preferencesStore: preferencesStore)
            return FloatingPillWindowController(
                clipboardStore: repository,
                preferencesStore: preferencesStore)
        } catch {
            return FloatingPillWindowController(
                clipboardStore: nil,
                preferencesStore: preferencesStore,
                startupError: error.localizedDescription)
        }
    }
}
