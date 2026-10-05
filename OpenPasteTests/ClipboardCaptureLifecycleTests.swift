import Foundation
import GRDB
import Testing
@testable import OpenPaste

@MainActor
struct ClipboardCaptureLifecycleTests {
    @Test
    func monitorReleasesItsPollingTaskWhenDeallocated() async throws {
        let pasteboard = FakeClipboardPasteboard()
        var monitor: ClipboardMonitor? = ClipboardMonitor(
            pasteboard: pasteboard,
            pollingInterval: .milliseconds(5))
        let reference = WeakClipboardMonitorReference(monitor)

        monitor?.start { _, _ in }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while pasteboard.pollCount < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pasteboard.pollCount >= 2)
        monitor = nil

        #expect(reference.monitor == nil)
    }

    @Test
    func monitorSuppressesOnlyTheInternalPasteboardChangeCount() async throws {
        let pasteboard = FakeClipboardPasteboard()
        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollingInterval: .milliseconds(5))
        let captured = ClipboardCaptureProbe()
        monitor.start { payload, _ in captured.values.append(payload.content) }

        pasteboard.write("OpenPaste payload")
        monitor.suppress(changeCount: pasteboard.currentChangeCount)
        try await Task.sleep(for: .milliseconds(30))
        pasteboard.write("External copy")
        try await Task.sleep(for: .milliseconds(30))

        #expect(captured.values == ["External copy"])
        monitor.stop()
    }

    @Test
    func capturePauseDiscardsCopiesUntilResumeAndThenCapturesNewWrites() async throws {
        let pasteboard = FakeClipboardPasteboard()
        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollingInterval: .milliseconds(5))
        let store = RecordingClipboardStore()
        let preferences = MemoryPreferencesStore()
        let service = ClipboardCaptureService(monitor: monitor)
        service.start(store: store, preferencesStore: preferences)

        pasteboard.write("before pause")
        #expect(await waitForCompletedCopies(store, count: 1))

        service.pause(for: .untilResumed)
        pasteboard.write("while paused")
        try await Task.sleep(for: .milliseconds(40))
        #expect(await store.completedCopies() == ["before pause"])
        #expect(preferences.preferences.capturePauseState == .pausedUntilResumed)

        service.resume()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await store.completedCopies() == ["before pause"])

        pasteboard.write("after resume")
        #expect(await waitForCompletedCopies(store, count: 2))
        #expect(await store.completedCopies() == ["before pause", "after resume"])
        service.stop()
    }

    @Test
    func stoppingCaptureDoesNotCancelARecordAlreadyInFlight() async throws {
        let pasteboard = FakeClipboardPasteboard()
        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollingInterval: .milliseconds(5))
        let store = RecordingClipboardStore()
        await store.blockNextCopy()
        let service = ClipboardCaptureService(monitor: monitor)
        service.start(store: store, preferencesStore: MemoryPreferencesStore())

        pasteboard.write("copy in flight")
        #expect(await waitForEnteredCopies(store, count: 1))
        service.stop()

        await store.releaseBlockedCopy()
        #expect(await waitForCompletedCopies(store, count: 1))
        #expect(await store.completedCopies() == ["copy in flight"])
    }

    private func waitForCompletedCopies(
        _ store: RecordingClipboardStore,
        count: Int
    ) async -> Bool {
        for _ in 0..<100 {
            if await store.completedCopies().count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await store.completedCopies().count >= count
    }

    private func waitForEnteredCopies(
        _ store: RecordingClipboardStore,
        count: Int
    ) async -> Bool {
        for _ in 0..<100 {
            if await store.enteredCopyCount() >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await store.enteredCopyCount() >= count
    }
}

@MainActor
private final class ClipboardCaptureProbe {
    var values: [String] = []
}

@MainActor
private final class WeakClipboardMonitorReference {
    weak var monitor: ClipboardMonitor?

    init(_ monitor: ClipboardMonitor?) {
        self.monitor = monitor
    }
}

@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboardReading {
    private var generation = 0
    private(set) var pollCount = 0
    var changeCount: Int {
        pollCount += 1
        return generation
    }
    var currentChangeCount: Int { generation }
    private(set) var content: String?
    var sourceApplicationBundleIdentifier: String? = "com.example.source"

    func payloadContents() -> ClipboardPayload? {
        content.map(ClipboardPayload.text)
    }

    func write(_ content: String) {
        self.content = content
        generation += 1
    }
}

@MainActor
private final class MemoryPreferencesStore: PreferencesStore {
    private(set) var preferences = AppPreferences.default

    func save(_ preferences: AppPreferences) {
        self.preferences = preferences
    }
}

private actor RecordingClipboardStore: ClipboardStore {
    private var enteredCount = 0
    private var completed: [String] = []
    private var shouldBlockNextCopy = false
    private var blockedCopy: CheckedContinuation<ClipboardItem?, any Error>?

    func blockNextCopy() {
        shouldBlockNextCopy = true
    }

    func releaseBlockedCopy() {
        blockedCopy?.resume(returning: nil)
        blockedCopy = nil
    }

    func enteredCopyCount() -> Int {
        enteredCount
    }

    func completedCopies() -> [String] {
        completed
    }

    func recordCopy(
        _ content: String,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy
    ) async throws -> ClipboardItem? {
        enteredCount += 1
        guard shouldBlockNextCopy else {
            completed.append(content)
            return nil
        }
        shouldBlockNextCopy = false
        let result = try await withCheckedThrowingContinuation { continuation in
            blockedCopy = continuation
        }
        completed.append(content)
        return result
    }

    func history(limit: Int) async throws -> [ClipboardItem] { [] }
    func collections() async throws -> [ClipboardCollection] { [] }
    func collectionItems(collectionID: Int64, limit: Int) async throws -> [ClipboardItem] { [] }
    func search(query: String, limit: Int, offset: Int) async throws -> [ClipboardItem] { [] }

    func observeHistory(limit: Int) async -> AsyncValueObservation<[ClipboardItem]> {
        fatalError("Not used by capture lifecycle tests")
    }

    func observeCollections() async -> AsyncValueObservation<[ClipboardCollection]> {
        fatalError("Not used by capture lifecycle tests")
    }

    func observeCollection(
        collectionID: Int64,
        limit: Int
    ) async -> AsyncValueObservation<[ClipboardItem]> {
        fatalError("Not used by capture lifecycle tests")
    }

    func createCollection(name: String, createdAt: Date) async throws -> ClipboardCollection {
        fatalError("Not used by capture lifecycle tests")
    }

    func moveToCollection(itemID: Int64, collectionID: Int64?) async throws {}
    func removeFromHistory(itemID: Int64) async throws {}
    func deletePermanently(itemID: Int64) async throws {}
    func removeCollection(collectionID: Int64) async throws {}
    func clearHistory() async throws {}
    func pruneExpiredHistory(now: Date) async throws {}
}
