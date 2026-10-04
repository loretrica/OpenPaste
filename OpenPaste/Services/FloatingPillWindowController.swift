import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PillWindowState {
    var isCompact = false

    func update(forHeight height: CGFloat) {
        isCompact = PillWindowGeometry.isCompact(height: height)
    }
}

enum PillWindowGeometry {
    static let compactHeightThreshold: CGFloat = 320
    static let horizontalMargin: CGFloat = 24
    static let maximumCompactCardSide: CGFloat = 220
    static let maximumFullCardSide: CGFloat = 320

    static func cardSide(availableHeight: CGFloat, isCompact: Bool) -> CGFloat {
        let maximumSide = isCompact ? maximumCompactCardSide : maximumFullCardSide
        return max(1, min(availableHeight, maximumSide))
    }

    static func frame(
        for dimensions: WindowDimensions,
        in visibleFrame: CGRect,
        bottomInset: CGFloat = 18
    ) -> CGRect {
        let safeWidth = max(1, visibleFrame.width - horizontalMargin * 2)
        let safeHeight = max(1, visibleFrame.height - bottomInset)
        let size = WindowDimensions(width: safeWidth, height: dimensions.height)
            .clamped(to: CGSize(width: safeWidth, height: safeHeight))
        return CGRect(
            x: visibleFrame.minX + (visibleFrame.width - size.width) / 2,
            y: visibleFrame.minY + bottomInset,
            width: size.width,
            height: size.height)
    }

    static func isCompact(height: CGFloat) -> Bool {
        height <= compactHeightThreshold
    }
}

@MainActor
final class FloatingPillWindowController: NSWindowController, NSWindowDelegate {
    private let clipboardStore: (any ClipboardStore)?
    private let preferencesStore: any PreferencesStore
    private let pillState = PillWindowState()
    private weak var previousApplication: NSRunningApplication?
    private var isDismissing = false
    private var isRepositioning = false
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(
        clipboardStore: (any ClipboardStore)?,
        preferencesStore: any PreferencesStore,
        startupError: String? = nil
    ) {
        self.clipboardStore = clipboardStore
        self.preferencesStore = preferencesStore

        let initialFrame = PillWindowGeometry.frame(
            for: preferencesStore.preferences.windowDimensions,
            in: NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        super.init(window: panel)

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
        panel.contentView = NSHostingView(
            rootView: ContentView(
                store: clipboardStore,
                startupError: startupError,
                preferencesStore: preferencesStore,
                pillState: pillState,
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
            panel.makeKeyAndOrderFront(nil)
            return
        }

        previousApplication = NSWorkspace.shared.frontmostApplication
        let screen = activeScreen()
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
        panel.makeKeyAndOrderFront(nil)
        installClickMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss(restoreFocus: Bool) {
        guard let panel = window, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        removeClickMonitors()
        panel.orderOut(nil)
        if restoreFocus, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [.activateIgnoringOtherApps])
        }
        isDismissing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isDismissing else { return }
        dismiss(restoreFocus: false)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = window, panel.isVisible, !isRepositioning else { return }
        pillState.update(forHeight: panel.frame.height)
        repositionAtBottom(of: activeScreen())
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = window else { return }
        let dimensions = WindowDimensions(width: panel.frame.width, height: panel.frame.height)
        var preferences = preferencesStore.preferences
        preferences.windowDimensions = dimensions
        preferencesStore.save(preferences)
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

    private func installClickMonitors() {
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }
        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownEvents) { [weak self] event in
            guard let self, self.isPillVisible, let panel = self.window else { return event }
            if !panel.frame.contains(NSEvent.mouseLocation) {
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
                      !panel.frame.contains(clickLocation)
                else {
                    return
                }
                self.dismiss(restoreFocus: false)
            }
        }
    }

    private func activeScreen() -> NSScreen? {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontmostPID,
           let windowFrame = frontmostWindowFrame(processID: frontmostPID),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) {
            return screen
        }

        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    private func frontmostWindowFrame(processID: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return nil
        }

        for windowInfo in windows {
            guard let owner = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  owner == processID,
                  let bounds = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else {
                continue
            }
            return frame
        }
        return nil
    }
}
