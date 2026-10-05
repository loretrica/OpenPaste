import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private let pasteboard: any ClipboardPasteboardReading
    private let pollingInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var lastChangeCount: Int?
    private var suppressedChangeCounts = Set<Int>()

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

    func suppress(changeCount: Int) {
        suppressedChangeCounts.insert(changeCount)
        if suppressedChangeCounts.count > 128 {
            suppressedChangeCounts.removeAll(keepingCapacity: true)
            suppressedChangeCounts.insert(changeCount)
        }
    }

    func start(onCopy: @escaping @MainActor (ClipboardPayload, String?) -> Void) {
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
        suppressedChangeCounts.removeAll()
    }

    private func checkPasteboard(onCopy: @MainActor (ClipboardPayload, String?) -> Void) {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if suppressedChangeCounts.remove(changeCount) != nil { return }
        guard let payload = pasteboard.payloadContents() else { return }

        let sourceBundleID = pasteboard.sourceApplicationBundleIdentifier
        guard sourceBundleID != Bundle.main.bundleIdentifier else { return }
        onCopy(payload, sourceBundleID)
    }
}
