import Foundation
import GRDB
import UniformTypeIdentifiers

actor ClipboardRepository: ClipboardStore {
    private let database: AppDatabase
    private let metadataLoader: any LinkMetadataLoading
    private let assetStore: any ClipboardAssetStore
    private var metadataTasks: [Int64: Task<Void, Never>] = [:]
    private var mutationLocked = false
    private var mutationWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(
        database: AppDatabase,
        metadataLoader: any LinkMetadataLoading = URLSessionMetadataLoader(),
        assetStore: (any ClipboardAssetStore)? = nil
    ) {
        self.database = database
        self.metadataLoader = metadataLoader
        self.assetStore = assetStore ?? FileClipboardAssetStore()
    }

    deinit {
        metadataTasks.values.forEach { $0.cancel() }
    }

    private func withMutationLock<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await acquireMutationLock()
        defer { releaseMutationLock() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquireMutationLock() async throws {
        try Task.checkCancellation()
        if !mutationLocked {
            mutationLocked = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                mutationWaiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelMutationWaiter(waiterID) }
        }
    }

    private func releaseMutationLock() {
        if mutationWaiters.isEmpty {
            mutationLocked = false
        } else {
            let next = mutationWaiters.removeFirst()
            next.continuation.resume(returning: ())
        }
    }

    private func cancelMutationWaiter(_ id: UUID) {
        guard let index = mutationWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = mutationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func recordCopy(
        _ content: String,
        sourceAppBundleID: String?,
        copiedAt: Date = .now,
        retentionPolicy: ClipboardRetentionPolicy = .oneMonth
    ) async throws -> ClipboardItem? {
        guard !content.isEmpty else { return nil }
        return try await recordCopy(
            ClipboardClassifier.classify(content),
            sourceAppBundleID: sourceAppBundleID,
            copiedAt: copiedAt,
            retentionPolicy: retentionPolicy)
    }

    func recordCopy(
        _ payload: ClipboardPayload,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy
    ) async throws -> ClipboardItem? {
        try await withMutationLock {
            try await recordCopySerialized(
                payload,
                sourceAppBundleID: sourceAppBundleID,
                copiedAt: copiedAt,
                retentionPolicy: retentionPolicy)
        }
    }

    private func recordCopySerialized(
        _ payload: ClipboardPayload,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy
    ) async throws -> ClipboardItem? {
        guard !payload.content.isEmpty || !payload.representations.isEmpty || !payload.files.isEmpty else {
            return nil
        }

        var validatedPayload = payload
        if payload.kind == .link {
            guard URLIdentity.canonicalize(payload.content) != nil else {
                throw ClipboardStoreError.invalidLink
            }
        }
        if payload.kind == .color {
            guard let color = ClipboardClassifier.normalizeColor(payload.colorHex ?? payload.content) else {
                throw ClipboardStoreError.invalidColor
            }
            validatedPayload.colorHex = color
        }
        if payload.kind == .code {
            validatedPayload.codeLanguage = ClipboardClassifier.normalizeCodeLanguage(payload.codeLanguage)
        }

        let previousItem = try await database.item(deduplicationKey: validatedPayload.deduplicationKey)
        var payloadToSave = validatedPayload
        if validatedPayload.representations.isEmpty,
           validatedPayload.files.isEmpty,
           previousItem?.content == validatedPayload.content,
           let previousPath = previousItem?.assetPath,
           let previousPayload = try? await assetStore.load(at: previousPath) {
            payloadToSave.representations = previousPayload.representations
            payloadToSave.files = previousPayload.files
        }
        let oldAssetPath = previousItem?.assetPath
        let newAssetPath: String?
        if payloadToSave.representations.isEmpty && payloadToSave.files.isEmpty {
            newAssetPath = nil
        } else {
            newAssetPath = try await assetStore.save(payloadToSave)
        }
        do {
            let item = try await database.recordCopy(
                payload: payloadToSave,
                assetPath: newAssetPath,
                sourceAppBundleID: sourceAppBundleID,
                copiedAt: copiedAt,
                retentionPolicy: retentionPolicy)

            if let oldAssetPath, oldAssetPath != newAssetPath {
                try? await assetStore.delete(at: oldAssetPath)
            }
            if payloadToSave.kind == .link,
               item.title == nil,
               item.linkDescription == nil,
               let canonicalURL = payloadToSave.canonicalURL,
               let url = URL(string: canonicalURL),
               let itemID = item.id {
                enqueueMetadata(for: url, itemID: itemID)
            }
            return item
        } catch {
            if let newAssetPath {
                try? await assetStore.delete(at: newAssetPath)
            }
            throw error
        }
    }

    func payload(for item: ClipboardItem) async throws -> ClipboardPayload {
        try await withMutationLock {
            try await payloadSerialized(for: item)
        }
    }

    private func payloadSerialized(for item: ClipboardItem) async throws -> ClipboardPayload {
        let stored: ClipboardPayload
        if let assetPath = item.assetPath {
            stored = try await assetStore.load(at: assetPath)
        } else {
            stored = ClipboardPayload.restoring(item)
        }
        return ClipboardPayload(
            kind: item.kind,
            content: item.content,
            representations: stored.representations,
            files: stored.files,
            codeLanguage: item.codeLanguage,
            colorHex: item.colorHex,
            imageWidth: item.imageWidth,
            imageHeight: item.imageHeight)
    }

    func fetchItems(query: ClipboardQuery, limit: Int, offset: Int) async throws -> [ClipboardItem] {
        try await database.fetchItems(query: query, limit: limit, offset: offset)
    }

    func observeItems(query: ClipboardQuery, limit: Int) async -> AsyncValueObservation<[ClipboardItem]> {
        await database.observeItems(query: query, limit: limit)
    }

    func history(limit: Int) async throws -> [ClipboardItem] {
        try await database.history(limit: limit)
    }

    func collections() async throws -> [ClipboardCollection] {
        try await database.collections()
    }

    func sourceApplicationBundleIDs() async throws -> [String] {
        try await database.sourceApplicationBundleIDs()
    }

    func collectionItems(collectionID: Int64, limit: Int) async throws -> [ClipboardItem] {
        try await database.collectionItems(collectionID: collectionID, limit: limit)
    }

    func search(query: String, limit: Int, offset: Int = 0) async throws -> [ClipboardItem] {
        try await database.search(query: query, limit: limit, offset: offset)
    }

    func observeHistory(limit: Int = 100) async -> AsyncValueObservation<[ClipboardItem]> {
        await database.observeHistory(limit: limit)
    }

    func observeCollections() async -> AsyncValueObservation<[ClipboardCollection]> {
        await database.observeCollections()
    }

    func observeCollection(
        collectionID: Int64,
        limit: Int = 100
    ) async -> AsyncValueObservation<[ClipboardItem]> {
        await database.observeCollection(collectionID: collectionID, limit: limit)
    }

    func createCollection(name: String, createdAt: Date = .now) async throws -> ClipboardCollection {
        try await withMutationLock {
            try await database.createCollection(name: name, createdAt: createdAt)
        }
    }

    func updateCollection(collectionID: Int64, name: String, colorHex: String) async throws {
        try await withMutationLock {
            try await database.updateCollection(
                collectionID: collectionID,
                name: name,
                colorHex: colorHex)
        }
    }

    func reorderCollections(ids: [Int64]) async throws {
        try await withMutationLock {
            try await database.reorderCollections(ids: ids)
        }
    }

    func reorderItems(ids: [Int64], collectionID: Int64) async throws {
        try await withMutationLock {
            try await database.reorderItems(ids: ids, collectionID: collectionID)
        }
    }

    func renameItem(itemID: Int64, title: String?) async throws {
        try await withMutationLock {
            try await database.renameItem(itemID: itemID, title: title)
        }
    }

    func updateText(itemID: Int64, content: String, language: String?) async throws {
        try await withMutationLock {
            guard let item = try await database.item(id: itemID) else { return }
            var payload = try await payloadSerialized(for: item)
            if payload.content != content {
                payload.representations.removeAll { representation in
                    representation.type.lowercased() == "com.apple.flat-rtfd"
                        || UTType(representation.type)?.conforms(to: .text) == true
                }
            }
            payload.content = content
            payload.kind = language == nil ? .text : .code
            payload.codeLanguage = ClipboardClassifier.normalizeCodeLanguage(language)
            payload.colorHex = nil
            try await updatePayloadSerialized(itemID: itemID, payload: payload)
        }
    }

    func updatePayload(itemID: Int64, payload: ClipboardPayload) async throws {
        try await withMutationLock {
            try await updatePayloadSerialized(itemID: itemID, payload: payload)
        }
    }

    private func updatePayloadSerialized(itemID: Int64, payload: ClipboardPayload) async throws {
        guard try await database.item(id: itemID) != nil else {
            throw ClipboardStoreError.itemNotFound
        }
        var normalized = payload
        normalized.codeLanguage = ClipboardClassifier.normalizeCodeLanguage(payload.codeLanguage)
        normalized.colorHex = ClipboardClassifier.normalizeColor(payload.colorHex ?? "")
        let needsAsset = !normalized.representations.isEmpty || !normalized.files.isEmpty
        let assetPath: String?
        if needsAsset {
            assetPath = try await assetStore.save(normalized)
        } else {
            assetPath = nil
        }
        do {
            let oldAssetPath = try await database.updatePayload(
                itemID: itemID,
                payload: normalized,
                assetPath: assetPath)
            if let oldAssetPath, oldAssetPath != assetPath {
                try? await assetStore.delete(at: oldAssetPath)
            }
        } catch {
            if let assetPath {
                try? await assetStore.delete(at: assetPath)
            }
            throw error
        }
    }

    func setItemKind(itemID: Int64, kind: ClipboardItemKind, language: String?) async throws {
        try await withMutationLock {
            try await database.setItemKind(
                itemID: itemID,
                kind: kind,
                language: ClipboardClassifier.normalizeCodeLanguage(language))
        }
    }

    func moveItems(
        ids: [Int64],
        to collectionID: Int64?,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) async throws {
        try await withMutationLock {
            try await database.moveItems(
                ids: ids,
                to: collectionID,
                retentionPolicy: retentionPolicy,
                now: now)
        }
    }

    func deleteCollectionPreservingItems(
        collectionID: Int64,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) async throws {
        try await withMutationLock {
            try await database.deleteCollectionPreservingItems(
                collectionID: collectionID,
                retentionPolicy: retentionPolicy,
                now: now)
        }
    }

    func moveToCollection(itemID: Int64, collectionID: Int64?) async throws {
        try await withMutationLock {
            let assetPath = try await database.item(id: itemID)?.assetPath
            try await database.moveToCollection(itemID: itemID, collectionID: collectionID)
            try await cleanAssetIfItemWasDeleted(itemID: itemID, assetPath: assetPath)
        }
    }

    func removeFromHistory(itemID: Int64) async throws {
        try await withMutationLock {
            let assetPath = try await database.item(id: itemID)?.assetPath
            try await database.removeFromHistory(itemID: itemID)
            try await cleanAssetIfItemWasDeleted(itemID: itemID, assetPath: assetPath)
        }
    }

    func deletePermanently(itemID: Int64) async throws {
        try await withMutationLock {
            let assetPath = try await database.item(id: itemID)?.assetPath
            try await database.deletePermanently(itemID: itemID)
            try await cleanAssetIfItemWasDeleted(itemID: itemID, assetPath: assetPath)
        }
    }

    func removeCollection(collectionID: Int64) async throws {
        try await withMutationLock {
            let paths = Set(try await database.assetPaths())
            try await database.removeCollection(collectionID: collectionID)
            try await cleanOrphanedAssets(from: paths)
        }
    }

    func clearHistory() async throws {
        try await withMutationLock {
            let paths = Set(try await database.assetPaths())
            try await database.clearHistory()
            try await cleanOrphanedAssets(from: paths)
        }
    }

    func pruneExpiredHistory(now: Date = .now) async throws {
        try await withMutationLock {
            let paths = Set(try await database.assetPaths())
            try await database.pruneExpiredHistory(now: now)
            try await cleanOrphanedAssets(from: paths)
        }
    }

    private func cleanOrphanedAssets(from previousPaths: Set<String>) async throws {
        let currentPaths = Set(try await database.assetPaths())
        for relativePath in previousPaths.subtracting(currentPaths) {
            try? await assetStore.delete(at: relativePath)
        }
    }

    private func cleanAssetIfItemWasDeleted(itemID: Int64, assetPath: String?) async throws {
        guard let assetPath, try await database.item(id: itemID) == nil else { return }
        try? await assetStore.delete(at: assetPath)
    }

    private func enqueueMetadata(for url: URL, itemID: Int64) {
        guard metadataTasks[itemID] == nil else { return }

        let database = self.database
        let metadataLoader = self.metadataLoader
        metadataTasks[itemID] = Task { [weak self, database, metadataLoader] in
            do {
                if let metadata = try await metadataLoader.metadata(for: url) {
                    try Task.checkCancellation()
                    try await database.updateLinkMetadata(itemID: itemID, metadata: metadata)
                }
            } catch {
                // The saved URL remains available if metadata loading fails.
            }
            await self?.metadataTaskDidFinish(itemID: itemID)
        }
    }

    private func metadataTaskDidFinish(itemID: Int64) {
        metadataTasks[itemID] = nil
    }
}
