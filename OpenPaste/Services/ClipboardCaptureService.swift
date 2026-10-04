import Foundation
import OSLog

@MainActor
final class ClipboardCaptureService {
    static let shared = ClipboardCaptureService()

    private let monitor = ClipboardMonitor()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenPaste",
        category: "ClipboardCapture")
    private var isStarted = false

    private init() {}

    func start(store: any ClipboardStore) {
        guard !isStarted else { return }
        isStarted = true

        monitor.start { [logger] content, sourceBundleID in
            Task {
                do {
                    _ = try await store.recordCopy(
                        content,
                        sourceAppBundleID: sourceBundleID,
                        copiedAt: .now)
                } catch {
                    logger.error("Failed to save clipboard item: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
