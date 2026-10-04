import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private var pollingTask: Task<Void, Never>?
    private var lastChangeCount: Int?

    func start(onCopy: @escaping @MainActor (String, String?) -> Void) {
        guard pollingTask == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.checkPasteboard(onCopy: onCopy)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        lastChangeCount = nil
    }

    private func checkPasteboard(onCopy: @MainActor (String, String?) -> Void) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let content = pasteboard.string(forType: .string),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard sourceBundleID != Bundle.main.bundleIdentifier else { return }
        onCopy(content, sourceBundleID)
    }
}
