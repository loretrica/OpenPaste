import Foundation
import OSLog

enum CapturePauseDuration: Sendable {
    case fifteenMinutes
    case oneHour
    case untilResumed

    func state(startingAt date: Date = .now) -> CapturePauseState {
        switch self {
        case .fifteenMinutes:
            .pausedUntil(date.addingTimeInterval(15 * 60))
        case .oneHour:
            .pausedUntil(date.addingTimeInterval(60 * 60))
        case .untilResumed:
            .pausedUntilResumed
        }
    }
}

@MainActor
final class ClipboardCaptureService {
    static let shared = ClipboardCaptureService()

    private let monitor = ClipboardMonitor()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenPaste",
        category: "ClipboardCapture")
    private var store: (any ClipboardStore)?
    private var preferencesStore: (any PreferencesStore)?
    private var pruningTask: Task<Void, Never>?
    private var pauseExpirationTask: Task<Void, Never>?
    private var isStarted = false

    private init() {}

    func start(
        store: any ClipboardStore,
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore.shared
    ) {
        guard !isStarted else { return }
        isStarted = true
        self.store = store
        self.preferencesStore = preferencesStore

        startPruningTask()
        synchronizePauseState()
    }

    func pause(for duration: CapturePauseDuration) {
        guard let preferencesStore else { return }
        var preferences = preferencesStore.preferences
        preferences.capturePauseState = duration.state()
        preferencesStore.save(preferences)
        monitor.stop()
        schedulePauseExpiration(for: preferences.capturePauseState)
    }

    func resume() {
        guard let preferencesStore else { return }
        pauseExpirationTask?.cancel()
        pauseExpirationTask = nil

        var preferences = preferencesStore.preferences
        preferences.capturePauseState = .active
        preferencesStore.save(preferences)
        startMonitoringIfNeeded()
    }

    func stop() {
        monitor.stop()
        pruningTask?.cancel()
        pruningTask = nil
        pauseExpirationTask?.cancel()
        pauseExpirationTask = nil
        isStarted = false
        store = nil
        preferencesStore = nil
    }

    private func synchronizePauseState() {
        guard let preferencesStore else { return }
        let state = preferencesStore.preferences.capturePauseState
        if state.isPaused() {
            monitor.stop()
            schedulePauseExpiration(for: state)
        } else {
            if case .pausedUntil = state {
                var preferences = preferencesStore.preferences
                preferences.capturePauseState = .active
                preferencesStore.save(preferences)
            }
            startMonitoringIfNeeded()
        }
    }

    private func startMonitoringIfNeeded() {
        guard isStarted,
              let store,
              let preferencesStore,
              !preferencesStore.preferences.capturePauseState.isPaused()
        else {
            return
        }

        monitor.start { [weak self] content, sourceBundleID in
            guard let self,
                  let preferencesStore = self.preferencesStore,
                  !preferencesStore.preferences.capturePauseState.isPaused(),
                  let store = self.store
            else {
                return
            }

            let retentionPolicy = preferencesStore.preferences.retentionPolicy
            Task {
                do {
                    _ = try await store.recordCopy(
                        content,
                        sourceAppBundleID: sourceBundleID,
                        copiedAt: .now,
                        retentionPolicy: retentionPolicy)
                } catch {
                    self.logger.error(
                        "Failed to save clipboard item: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func schedulePauseExpiration(for state: CapturePauseState) {
        pauseExpirationTask?.cancel()
        pauseExpirationTask = nil

        guard case let .pausedUntil(until) = state else { return }
        pauseExpirationTask = Task { [weak self] in
            let delay = max(0, until.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.resume()
        }
    }

    private func startPruningTask() {
        pruningTask?.cancel()
        pruningTask = Task { [weak self] in
            guard let self else { return }
            await self.pruneExpiredItems()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                guard !Task.isCancelled else { return }
                await self.pruneExpiredItems()
            }
        }
    }

    private func pruneExpiredItems() async {
        guard let store else { return }
        do {
            try await store.pruneExpiredHistory(now: .now)
        } catch {
            logger.error(
                "Failed to prune expired clipboard items: \(error.localizedDescription, privacy: .public)")
        }
    }
}
