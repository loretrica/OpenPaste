import Foundation
import GRDB
import Testing
@testable import OpenPaste

struct ClipboardStoreTests {
    @Test
    func repeatedCopiesUpdateTheExistingItem() async throws {
        let store = try makeStore()
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(60)

        let first = try await store.recordCopy(
            "exact text",
            sourceAppBundleID: "com.example.first",
            copiedAt: firstDate)
        let second = try await store.recordCopy(
            "exact text",
            sourceAppBundleID: "com.example.second",
            copiedAt: secondDate)

        #expect(first?.id == second?.id)
        #expect(second?.firstCopiedAt == firstDate)
        #expect(second?.lastCopiedAt == secondDate)
        #expect(second?.sourceAppBundleID == "com.example.second")

        let history = try await store.history(limit: 20)
        #expect(history.count == 1)

        _ = try await store.recordCopy(
            " exact text",
            sourceAppBundleID: nil,
            copiedAt: secondDate)
        #expect(try await store.history(limit: 20).count == 2)
    }

    @Test
    func normalizedURLsShareAnIdentity() async throws {
        let store = try makeStore()
        let first = try await store.recordCopy(
            "HTTPS://ExAmPle.COM:443",
            sourceAppBundleID: "com.example.browser",
            copiedAt: Date(timeIntervalSince1970: 100))
        let second = try await store.recordCopy(
            "https://example.com/",
            sourceAppBundleID: "com.example.editor",
            copiedAt: Date(timeIntervalSince1970: 200))

        #expect(first?.id == second?.id)
        #expect(second?.canonicalURL == "https://example.com/")
        #expect(try await store.history(limit: 20).count == 1)
    }

    @Test
    func collectedItemsSurviveHistoryRemovalAndRetention() async throws {
        let store = try makeStore()
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let item = try #require(await store.recordCopy(
            "saved text",
            sourceAppBundleID: nil,
            copiedAt: oldDate,
            retentionPolicy: .oneDay))
        let itemID = try #require(item.id)
        let collection = try await store.createCollection(name: "Progetto", createdAt: oldDate)
        let collectionID = try #require(collection.id)

        try await store.moveToCollection(itemID: itemID, collectionID: collectionID)

        let collectionStream = await store.observeCollections()
        var collectionIterator = collectionStream.makeAsyncIterator()
        #expect(try await collectionIterator.next() == [collection])

        try await store.pruneExpiredHistory(now: Date(timeIntervalSince1970: 200_000))
        #expect(try await store.history(limit: 20).isEmpty)
        #expect(try await store.collectionItems(collectionID: collectionID, limit: 20).count == 1)

        try await store.removeCollection(collectionID: collectionID)
        #expect(try await collectionIterator.next()?.isEmpty == true)
        #expect(try await store.collectionItems(collectionID: collectionID, limit: 20).isEmpty)
        #expect(try await store.search(query: "saved", limit: 20, offset: 0).isEmpty)
    }

    @Test
    func retentionPolicyChangesOnlyAffectNewCopies() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let existingCopyDate = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let newCopyDate = now.addingTimeInterval(-2 * 24 * 60 * 60)

        let existing = try #require(await store.recordCopy(
            "existing under one month",
            sourceAppBundleID: nil,
            copiedAt: existingCopyDate,
            retentionPolicy: .oneMonth))
        let recent = try #require(await store.recordCopy(
            "new copy under one day",
            sourceAppBundleID: nil,
            copiedAt: newCopyDate,
            retentionPolicy: .oneDay))

        #expect(existing.expiresAt == ClipboardRetentionPolicy.oneMonth.expirationDate(relativeTo: existingCopyDate))
        #expect(recent.expiresAt == ClipboardRetentionPolicy.oneDay.expirationDate(relativeTo: newCopyDate))

        try await store.pruneExpiredHistory(now: now)

        let history = try await store.history(limit: 20)
        #expect(history.map { $0.content } == ["existing under one month"])
    }

    @Test
    func recopyRefreshesExpirationUsingCurrentRetentionPolicy() async throws {
        let store = try makeStore()
        let firstCopyDate = Date(timeIntervalSince1970: 2_000_000)
        let secondCopyDate = firstCopyDate.addingTimeInterval(60)

        _ = try await store.recordCopy(
            "repeated item",
            sourceAppBundleID: nil,
            copiedAt: firstCopyDate,
            retentionPolicy: .oneMonth)
        let repeated = try #require(await store.recordCopy(
            "repeated item",
            sourceAppBundleID: nil,
            copiedAt: secondCopyDate,
            retentionPolicy: .oneWeek))

        #expect(repeated.expiresAt == ClipboardRetentionPolicy.oneWeek.expirationDate(relativeTo: secondCopyDate))
    }

    @Test
    func removingAnItemFromHistoryDoesNotRemoveItsCollectionMembership() async throws {
        let store = try makeStore()
        let item = try #require(await store.recordCopy(
            "collection text",
            sourceAppBundleID: nil,
            copiedAt: .now))
        let itemID = try #require(item.id)
        let collection = try await store.createCollection(name: "Riferimenti", createdAt: .now)
        let collectionID = try #require(collection.id)

        try await store.moveToCollection(itemID: itemID, collectionID: collectionID)
        try await store.removeFromHistory(itemID: itemID)

        #expect(try await store.history(limit: 20).isEmpty)
        #expect(try await store.collectionItems(collectionID: collectionID, limit: 20).count == 1)
    }

    @Test
    func searchFindsMetadataAndUpdatesReactively() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = ClipboardRepository(database: database, metadataLoader: NoopMetadataLoader())
        let item = try await database.recordCopy(
            content: .link(
                rawURL: "https://example.com/",
                canonicalURL: "https://example.com/"),
            sourceAppBundleID: "com.example.browser",
            copiedAt: .now)
        let itemID = try #require(item.id)

        try await database.updateLinkMetadata(
            itemID: itemID,
            metadata: ClipboardLinkMetadata(
                title: "OpenPaste Reference",
                description: "A metadata phrase for the database"))

        #expect(try await store.search(query: "reference", limit: 20, offset: 0).count == 1)
        #expect(try await store.search(query: "metadata", limit: 20, offset: 0).count == 1)

        let stream = await store.observeHistory(limit: 20)
        var iterator = stream.makeAsyncIterator()
        let initialItems = try await iterator.next()
        #expect(initialItems?.count == 1)

        _ = try await store.recordCopy(
            "reactive update",
            sourceAppBundleID: nil,
            copiedAt: .now)
        let updatedItems = try await iterator.next()
        #expect(updatedItems?.count == 2)
    }

    @Test
    func metadataFailureDoesNotDiscardTheCopiedURL() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = ClipboardRepository(database: database, metadataLoader: FailingMetadataLoader())

        let item = try await store.recordCopy(
            "https://example.com/",
            sourceAppBundleID: nil,
            copiedAt: .now)

        #expect(item?.kind == .link)
        #expect(item?.canonicalURL == "https://example.com/")
        #expect(try await store.history(limit: 20).count == 1)
    }

    @Test
    func concurrentCopiesRemainDeduplicated() async throws {
        let store = try makeStore()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    _ = try await store.recordCopy(
                        "one concurrent item",
                        sourceAppBundleID: "com.example.app\(index)",
                        copiedAt: baseDate.addingTimeInterval(Double(index)))
                }
            }
            try await group.waitForAll()
        }

        #expect(try await store.history(limit: 20).count == 1)
    }

    @Test
    func persistentDatabaseSurvivesReopening() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("OpenPaste.sqlite").path

        let firstDatabase = try AppDatabase(path: path)
        let firstStore = ClipboardRepository(
            database: firstDatabase,
            metadataLoader: NoopMetadataLoader())
        _ = try await firstStore.recordCopy(
            "persistent item",
            sourceAppBundleID: "com.example.app",
            copiedAt: .now)

        let reopenedDatabase = try AppDatabase(path: path)
        let reopenedStore = ClipboardRepository(
            database: reopenedDatabase,
            metadataLoader: NoopMetadataLoader())
        let items = try await reopenedStore.history(limit: 10)
        #expect(items.count == 1)
        #expect(items.first?.content == "persistent item")
    }

    @Test
    func metadataLoaderSkipsPrivateNetworkURLs() async throws {
        let url = try #require(URL(string: "http://10.0.0.1/"))
        let metadata = try await URLSessionMetadataLoader().metadata(for: url)
        #expect(metadata == nil)
    }

    @Test
    func fullTextSearchScalesToOneHundredThousandItems() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = ClipboardRepository(database: database, metadataLoader: NoopMetadataLoader())
        try await database.seedBenchmarkData(
            count: 100_000,
            at: Date(timeIntervalSince1970: 1_700_000_000))

        var durations: [TimeInterval] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let results = try await store.search(query: "raremark", limit: 20, offset: 0)
            let elapsed = ContinuousClock.now - start
            let duration = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            durations.append(duration)
            #expect(results.count == 1)
        }

        durations.sort()
        let percentile95 = durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))]
        #expect(percentile95 < 0.2)
    }

    private func makeStore() throws -> ClipboardRepository {
        ClipboardRepository(
            database: try AppDatabase.makeInMemory(),
            metadataLoader: NoopMetadataLoader())
    }
}

private struct NoopMetadataLoader: LinkMetadataLoading {
    func metadata(for url: URL) async throws -> ClipboardLinkMetadata? {
        nil
    }
}

private struct FailingMetadataLoader: LinkMetadataLoading {
    enum ExpectedFailure: Error {
        case unavailable
    }

    func metadata(for url: URL) async throws -> ClipboardLinkMetadata? {
        throw ExpectedFailure.unavailable
    }
}
