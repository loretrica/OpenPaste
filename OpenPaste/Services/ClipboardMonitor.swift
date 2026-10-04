import AppKit
import Foundation

@MainActor
private final class AppKitClipboardPasteboardReader: ClipboardPasteboardReading {
    var changeCount: Int { NSPasteboard.general.changeCount }

    func stringContents() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    var sourceApplicationBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

@MainActor
final class ClipboardMonitor {
    private let pasteboard: any ClipboardPasteboardReading
    private let pollingInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var lastChangeCount: Int?

    init(
        pasteboard: any ClipboardPasteboardReading = AppKitClipboardPasteboardReader(),
        pollingInterval: Duration = .milliseconds(250)
    ) {
        self.pasteboard = pasteboard
        self.pollingInterval = pollingInterval
    }

    deinit {
        pollingTask?.cancel()
    }

    func start(onCopy: @escaping @MainActor (String, String?) -> Void) {
        guard pollingTask == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let pollingInterval = self.pollingInterval

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkPasteboard(onCopy: onCopy)
                try? await Task.sleep(for: pollingInterval)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        lastChangeCount = nil
    }

    private func checkPasteboard(onCopy: @MainActor (String, String?) -> Void) {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        guard let content = ClipboardTextNormalizer.acceptedContent(pasteboard.stringContents()) else {
            return
        }

        let sourceBundleID = pasteboard.sourceApplicationBundleIdentifier
        guard sourceBundleID != Bundle.main.bundleIdentifier else { return }
        onCopy(content, sourceBundleID)
    }
}
