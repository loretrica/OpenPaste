import AppKit
import QuickLookUI
import SwiftUI

@MainActor
final class FloatingPillWindowController: NSWindowController, NSWindowDelegate {
    private let clipboardStore: (any ClipboardStore)?
    private let preferencesStore: any PreferencesStore
    private let onPause: (CapturePauseDuration) -> Void
    private let onResume: () -> Void
    private let onPasteboardWrite: (Int) -> Void
    private let pasteService: ClipboardPasteService
    private let actionStatus = ClipboardActionStatus()
    private let pillState = PillWindowState()
    private lazy var previewController = ClipboardQuickLookController { [weak self] isControlling in
        self?.holdInteraction(isControlling)
    }
    private var previousApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var applicationActivationObserver: NSObjectProtocol?
    private var interactionHoldCount = 0
    private var isDismissing = false
    private var isRepositioning = false
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(
        clipboardStore: (any ClipboardStore)?,
        preferencesStore: any PreferencesStore,
        startupError: String? = nil,
        onPause: @escaping (CapturePauseDuration) -> Void = { _ in },
        onResume: @escaping () -> Void = {},
        onPasteboardWrite: @escaping (Int) -> Void = { _ in }
    ) {
        self.clipboardStore = clipboardStore
        self.preferencesStore = preferencesStore
        self.onPause = onPause
        self.onResume = onResume
        self.onPasteboardWrite = onPasteboardWrite
        #if DEBUG
        let pasteboard: NSPasteboard
        if ClipboardDemoData.isEnabled {
            pasteboard = NSPasteboard(name: NSPasteboard.Name(
                "it.lore-trica.openpaste.ui-tests.\(UUID().uuidString)"))
        } else {
            pasteboard = .general
        }
        #else
        let pasteboard = NSPasteboard.general
        #endif
        self.pasteService = ClipboardPasteService(pasteboard: pasteboard)

        let initialFrame = PillWindowGeometry.frame(
            for: preferencesStore.preferences.windowDimensions,
            in: NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        let panel = ClipboardPillPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        super.init(window: panel)

        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(application)
            }
        }

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(
            width: initialFrame.width,
            height: min(180, initialFrame.height))
        panel.maxSize = NSSize(
            width: initialFrame.width,
            height: max(initialFrame.height, NSScreen.main?.visibleFrame.height ?? initialFrame.height))
        panel.delegate = self
        let actions = ClipboardUIActions(
            paste: { [weak self] item, plainText in
                guard let self else { return }
                Task { @MainActor in await self.paste(item, plainText: plainText) }
            },
            copy: { [weak self] item in
                guard let self else { return }
                Task { @MainActor in await self.copy(item) }
            },
            preview: { [weak self] item in
                guard let self else { return }
                Task { @MainActor in await self.previewController.preview(item, using: self.clipboardStore) }
            },
            open: { [weak self] item in
                self?.open(item)
            },
            holdInteraction: { [weak self] isHeld in
                self?.holdInteraction(isHeld)
            },
            pause: { [weak self] duration in self?.onPause(duration) },
            resume: { [weak self] in self?.onResume() },
            status: actionStatus)
        panel.contentView = NSHostingView(
            rootView: ContentView(
                store: clipboardStore,
                startupError: startupError,
                preferencesStore: preferencesStore,
                pillState: pillState,
                actions: actions,
                onDismiss: { [weak self] in self?.dismiss(restoreFocus: true) }))
        pillState.update(forHeight: initialFrame.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var isPillVisible: Bool {
        window?.isVisible == true
    }

    func toggle() {
        isPillVisible ? dismiss(restoreFocus: true) : show()
    }

    func show() {
        guard let panel = window as? NSPanel else { return }
        if panel.isVisible {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            return
        }

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            rememberExternalApplication(frontmostApplication)
        }
        if previousApplication == nil || previousApplication?.isTerminated == true {
            previousApplication = lastExternalApplication
        }
        let screen = PillWindowScreenLocator.activeScreen()
        let visibleFrame = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let targetFrame = PillWindowGeometry.frame(
            for: preferencesStore.preferences.windowDimensions,
            in: visibleFrame)
        let availableWidth = max(
            1,
            visibleFrame.width - PillWindowGeometry.horizontalMargin * 2)
        panel.minSize = NSSize(
            width: availableWidth,
            height: min(180, max(1, visibleFrame.height - 18)))
        panel.maxSize = NSSize(
            width: availableWidth,
            height: max(1, visibleFrame.height - 18))

        panel.setFrame(targetFrame.offsetBy(dx: 0, dy: -28), display: false)
        panel.alphaValue = 0
        pillState.didPresent()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        installClickMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func rememberExternalApplication(_ application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated
        else { return }
        lastExternalApplication = application
        if isPillVisible {
            previousApplication = application
        }
    }

    private func holdInteraction(_ isHeld: Bool) {
        if isHeld {
            interactionHoldCount += 1
            return
        }

        interactionHoldCount = max(0, interactionHoldCount - 1)
    }

    private func copy(_ item: ClipboardItem) async {
        guard !actionStatus.isBusy else { return }
        actionStatus.isBusy = true
        holdInteraction(true)
        defer {
            actionStatus.isBusy = false
            holdInteraction(false)
        }

        await pasteService.copy(
            item,
            using: clipboardStore,
            onWrite: onPasteboardWrite)
        actionStatus.message = "Copiato"
    }

    private func paste(_ item: ClipboardItem, plainText: Bool) async {
        guard !actionStatus.isBusy else { return }
        actionStatus.isBusy = true
        holdInteraction(true)
        defer {
            actionStatus.isBusy = false
            holdInteraction(false)
        }

        let result = await pasteService.paste(
            item,
            using: clipboardStore,
            to: previousApplication,
            plainText: plainText,
            onWrite: onPasteboardWrite,
            onDismiss: { [weak self] in self?.dismiss(restoreFocus: false, force: true) })
        switch result {
        case .pasted:
            actionStatus.message = "Incollato"
        case .manualPasteRequired:
            actionStatus.message = "Copiato. Premi ⌘V nell’app di destinazione."
        }
    }

    private func preview(_ item: ClipboardItem) async {
        await previewController.preview(item, using: clipboardStore)
    }

    private func open(_ item: ClipboardItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let payload: ClipboardPayload
            if let store = clipboardStore, let restored = try? await store.payload(for: item) {
                payload = restored
            } else {
                payload = ClipboardPayload.restoring(item)
            }

            if let file = payload.files.first,
               let url = file.resolvedURL() {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: payload.content),
                      url.scheme != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func dismiss(restoreFocus: Bool, force: Bool = false) {
        guard let panel = window, panel.isVisible, !isDismissing else { return }
        guard force || interactionHoldCount == 0 else { return }
        isDismissing = true
        removeClickMonitors()
        panel.orderOut(nil)
        if restoreFocus, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
        isDismissing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isDismissing, interactionHoldCount == 0 else { return }
        dismiss(restoreFocus: false)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = window, panel.isVisible, !isRepositioning else { return }
        pillState.update(forHeight: panel.frame.height)
        repositionAtBottom(of: PillWindowScreenLocator.activeScreen())
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = window else { return }
        let dimensions = WindowDimensions(width: panel.frame.width, height: panel.frame.height)
        preferencesStore.update { $0.windowDimensions = dimensions }
    }

    private func repositionAtBottom(of screen: NSScreen?) {
        guard let panel = window, let screen else { return }
        let targetFrame = PillWindowGeometry.frame(
            for: WindowDimensions(width: panel.frame.width, height: panel.frame.height),
            in: screen.visibleFrame)
        guard abs(targetFrame.minX - panel.frame.minX) > 1
                || abs(targetFrame.minY - panel.frame.minY) > 1
        else {
            return
        }

        isRepositioning = true
        panel.setFrame(targetFrame, display: true)
        isRepositioning = false
    }

    private func removeClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func isInsidePreviewPanel(_ point: NSPoint) -> Bool {
        guard let previewPanel = QLPreviewPanel.shared(),
              previewPanel.isVisible
        else { return false }
        return previewPanel.frame.contains(point)
    }

    private func installClickMonitors() {
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }
        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownEvents) { [weak self] event in
            guard let self,
                  self.isPillVisible,
                  let panel = self.window
            else { return event }
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation), !self.isInsidePreviewPanel(clickLocation) {
                guard self.interactionHoldCount == 0 else { return event }
                self.dismiss(restoreFocus: false)
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownEvents) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self,
                      self.isPillVisible,
                      let panel = self.window,
                      !panel.frame.contains(clickLocation),
                      !self.isInsidePreviewPanel(clickLocation)
                else {
                    return
                }
                guard self.interactionHoldCount == 0 else { return }
                self.dismiss(restoreFocus: false)
            }
        }
    }
}

@MainActor
private final class ClipboardPillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
