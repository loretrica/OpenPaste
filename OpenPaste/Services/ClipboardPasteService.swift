import AppKit
import Carbon
import CoreGraphics
import Foundation

@MainActor
final class ClipboardPasteService {
    enum PasteResult {
        case pasted
        case manualPasteRequired
    }

    private let pasteboard: NSPasteboard
    private let workspace: NSWorkspace
    private var activationObserver: NSObjectProtocol?
    private var activationContinuation: CheckedContinuation<Bool, Never>?
    private var activationTimeout: Task<Void, Never>?
    private var requestedPostEventAccess = false

    init(pasteboard: NSPasteboard = .general, workspace: NSWorkspace = .shared) {
        self.pasteboard = pasteboard
        self.workspace = workspace
    }

    func copy(
        _ item: ClipboardItem,
        using store: (any ClipboardStore)?,
        plainText: Bool = false,
        onWrite: (Int) -> Void = { _ in }
    ) async {
        let payload = await loadPayload(for: item, using: store)
        write(payload, plainText: plainText)
        onWrite(pasteboard.changeCount)
    }

    func paste(
        _ item: ClipboardItem,
        using store: (any ClipboardStore)?,
        to targetApplication: NSRunningApplication?,
        plainText: Bool = false,
        onWrite: (Int) -> Void = { _ in },
        onDismiss: () -> Void
    ) async -> PasteResult {
        let payload = await loadPayload(for: item, using: store)
        let hasPostEventAccess: Bool
        if CGPreflightPostEventAccess() {
            hasPostEventAccess = true
        } else if !requestedPostEventAccess {
            requestedPostEventAccess = true
            hasPostEventAccess = CGRequestPostEventAccess()
        } else {
            hasPostEventAccess = false
        }
        write(payload, plainText: plainText)
        onWrite(pasteboard.changeCount)

        guard let targetApplication, !targetApplication.isTerminated else {
            return .manualPasteRequired
        }

        onDismiss()
        guard targetApplication.activate(options: []),
              await waitUntilActive(targetApplication)
        else {
            return .manualPasteRequired
        }

        guard hasPostEventAccess,
              targetApplication.isActive,
              postCommandV()
        else {
            return .manualPasteRequired
        }
        return .pasted
    }

    func write(_ payload: ClipboardPayload, plainText: Bool = false) {
        pasteboard.clearContents()
        let payloads: [ClipboardPayload]
        if !plainText, payload.files.count > 1 {
            payloads = payload.files.map { file in
                var singleFilePayload = payload
                singleFilePayload.files = [file]
                singleFilePayload.content = file.name
                return singleFilePayload
            }
        } else {
            payloads = [payload]
        }
        let items = payloads.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            ClipboardPasteboardItemWriter.write(
                payload,
                to: item,
                plainText: plainText)
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func loadPayload(
        for item: ClipboardItem,
        using store: (any ClipboardStore)?
    ) async -> ClipboardPayload {
        guard let store, let payload = try? await store.payload(for: item) else {
            return ClipboardPayload.restoring(item)
        }
        return payload
    }

    private func waitUntilActive(_ application: NSRunningApplication) async -> Bool {
        if application.isActive { return true }
        let processIdentifier = application.processIdentifier
        activationTimeout?.cancel()
        if let activationObserver {
            workspace.notificationCenter.removeObserver(activationObserver)
        }

        return await withCheckedContinuation { continuation in
            activationContinuation = continuation
            activationObserver = workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: workspace,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier == processIdentifier
                else { return }
                Task { @MainActor [weak self] in
                    self?.finishActivationWait(true)
                }
            }
            activationTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.finishActivationWait(application.isActive)
            }
            if application.isActive {
                finishActivationWait(true)
            }
        }
    }

    private func finishActivationWait(_ active: Bool) {
        activationTimeout?.cancel()
        activationTimeout = nil
        if let activationObserver {
            workspace.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        let continuation = activationContinuation
        activationContinuation = nil
        continuation?.resume(returning: active)
    }

    private func postCommandV() -> Bool {
        guard let commandDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_Command),
                keyDown: true),
              let pasteDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true),
              let pasteUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false),
              let commandUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_Command),
                keyDown: false)
        else {
            return false
        }

        pasteDown.flags = .maskCommand
        pasteUp.flags = .maskCommand
        commandDown.post(tap: .cghidEventTap)
        pasteDown.post(tap: .cghidEventTap)
        pasteUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }
}
