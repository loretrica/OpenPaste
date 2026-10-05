import AppKit
import Foundation
import GRDB
import Testing
@testable import OpenPaste

struct ClipboardDataContractTests {
    @Test
    func imagePayloadRoundTripsThroughInjectedAssetDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try AppDatabase.makeInMemory()
        let assets = FileClipboardAssetStore(directory: directory)
        let store = ClipboardRepository(
            database: database,
            metadataLoader: EmptyMetadataLoader(),
            assetStore: assets)
        let payload = ClipboardPayload(
            kind: .image,
            content: "image/png",
            representations: [
                ClipboardRepresentation(type: "public.png", data: Data([1, 2, 3, 4]))
            ],
            imageWidth: 20,
            imageHeight: 30)

        let item = try #require(await store.recordCopy(
            payload,
            sourceAppBundleID: "com.example.editor",
            copiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            retentionPolicy: .oneMonth))
        let restored = try await store.payload(for: item)

        #expect(item.kind == .image)
        #expect(item.assetPath != nil)
        #expect(restored == payload)
    }

    @Test
    func sourceApplicationBundleIDsIncludeCollectionOnlyAndLaterHistoryRows() async throws {
        let store = ClipboardRepository(
            database: try AppDatabase.makeInMemory(),
            metadataLoader: EmptyMetadataLoader())
        let copiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<130 {
            let source = index == 0 ? "com.example.latepage" : "com.example.recent"
            _ = try await store.recordCopy(
                ClipboardPayload(kind: .text, content: "source page item \(index)"),
                sourceAppBundleID: source,
                copiedAt: copiedAt.addingTimeInterval(Double(index)),
                retentionPolicy: .forever)
        }

        let collectionOnly = try #require(await store.recordCopy(
            ClipboardPayload(kind: .text, content: "collection-only source"),
            sourceAppBundleID: "com.example.collectiononly",
            copiedAt: copiedAt.addingTimeInterval(-86_400),
            retentionPolicy: .oneDay))
        let collection = try await store.createCollection(name: "Archived source", createdAt: copiedAt)
        let collectionID = try #require(collection.id)
        try await store.moveToCollection(
            itemID: try #require(collectionOnly.id),
            collectionID: collectionID)
        try await store.pruneExpiredHistory(now: copiedAt.addingTimeInterval(10 * 86_400))

        let firstPageSources = Set(try await store.history(limit: 100).compactMap(\.sourceAppBundleID))
        #expect(!firstPageSources.contains("com.example.latepage"))
        #expect(!firstPageSources.contains("com.example.collectiononly"))

        let sourceIDs = try await store.sourceApplicationBundleIDs()
        #expect(sourceIDs == [
            "com.example.collectiononly",
            "com.example.latepage",
            "com.example.recent"
        ])
    }

    @Test
    func queryFiltersAndOffsetsPastOneHundredRows() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = ClipboardRepository(database: database, metadataLoader: EmptyMetadataLoader())
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<130 {
            _ = try await store.recordCopy(
                ClipboardPayload(kind: .code, content: "print(\(index))", codeLanguage: "Swift"),
                sourceAppBundleID: index.isMultiple(of: 2) ? "com.example.editor" : "com.example.other",
                copiedAt: start.addingTimeInterval(Double(index)),
                retentionPolicy: .forever)
        }

        let query = ClipboardQuery(
            scope: .all,
            filter: ClipboardFilter(
                kind: .code,
                sourceAppBundleID: "com.example.editor",
                fromDate: start,
                toDate: start.addingTimeInterval(128)))
        let page = try await store.fetchItems(query: query, limit: 15, offset: 50)

        #expect(page.count == 15)
        #expect(page.allSatisfy {
            $0.kind == .code && $0.sourceAppBundleID == "com.example.editor"
        })
        #expect(try await store.fetchItems(query: query, limit: 100, offset: 100).count == 0)
    }

    @Test
    func deletingCollectionReturnsExpiredItemsToHistoryWithoutChangingCopyDate() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = ClipboardRepository(database: database, metadataLoader: EmptyMetadataLoader())
        let copiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = copiedAt.addingTimeInterval(10 * 24 * 60 * 60)
        let item = try #require(await store.recordCopy(
            ClipboardPayload(kind: .text, content: "kept text"),
            sourceAppBundleID: nil,
            copiedAt: copiedAt,
            retentionPolicy: .oneDay))
        let itemID = try #require(item.id)
        let collection = try await store.createCollection(name: "Keep", createdAt: copiedAt)
        let collectionID = try #require(collection.id)

        try await store.moveItems(
            ids: [itemID],
            to: collectionID,
            retentionPolicy: .oneDay,
            now: copiedAt)
        try await store.pruneExpiredHistory(now: now)
        #expect(try await store.history(limit: 10).isEmpty)

        try await store.deleteCollectionPreservingItems(
            collectionID: collectionID,
            retentionPolicy: .oneWeek,
            now: now)
        let restoredItems = try await store.history(limit: 10)
        let restored = try #require(restoredItems.first)

        #expect(restored.id == itemID)
        #expect(restored.firstCopiedAt == copiedAt)
        #expect(restored.lastCopiedAt == copiedAt)
        #expect(restored.expiresAt == ClipboardRetentionPolicy.oneWeek.expirationDate(relativeTo: now))
    }

    @Test
    func payloadEditsPreserveRichRepresentationsIdentityAndPlacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.makeInMemory()
        let assets = FileClipboardAssetStore(directory: directory)
        let store = ClipboardRepository(
            database: database,
            metadataLoader: EmptyMetadataLoader(),
            assetStore: assets)
        let original = ClipboardPayload(
            kind: .text,
            content: "formatted text",
            representations: [
                ClipboardRepresentation(type: "public.rtf", data: Data([10, 20, 30]))
            ])
        let item = try #require(await store.recordCopy(
            original,
            sourceAppBundleID: nil,
            copiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            retentionPolicy: .forever))
        let itemID = try #require(item.id)
        let collection = try await store.createCollection(name: "Rich", createdAt: .now)
        let collectionID = try #require(collection.id)
        try await store.moveItems(
            ids: [itemID],
            to: collectionID,
            retentionPolicy: .forever,
            now: .now)
        try await store.reorderItems(ids: [itemID], collectionID: collectionID)
        try await store.renameItem(itemID: itemID, title: "Editorial title")

        var edited = try await store.payload(for: item)
        edited.content = "edited formatted text"
        edited.kind = .code
        edited.codeLanguage = "Swift"
        try await store.updatePayload(itemID: itemID, payload: edited)

        _ = try await store.recordCopy(
            ClipboardPayload(kind: .text, content: "edited formatted text"),
            sourceAppBundleID: nil,
            copiedAt: Date(timeIntervalSince1970: 1_700_000_060),
            retentionPolicy: .forever)
        let collectionItems = try await store.collectionItems(
            collectionID: collectionID,
            limit: 10)
        let updatedItem = try #require(collectionItems.first)
        let updatedPayload = try await store.payload(for: updatedItem)
        #expect(updatedItem.id == itemID)
        #expect(updatedItem.collectionID == collectionID)
        #expect(updatedItem.customTitle == "Editorial title")
        #expect(updatedItem.kind == .code)
        #expect(updatedItem.codeLanguage == "Swift")
        #expect(updatedPayload.representations == original.representations)
        #expect(updatedPayload.content == "edited formatted text")
    }

    @Test
    func payloadEditDedupConflictLeavesOriginalRowsIntact() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = ClipboardRepository(database: database, metadataLoader: EmptyMetadataLoader())
        let first = try #require(await store.recordCopy(
            ClipboardPayload(kind: .text, content: "first"),
            sourceAppBundleID: nil,
            copiedAt: .now,
            retentionPolicy: .forever))
        _ = try await store.recordCopy(
            ClipboardPayload(kind: .text, content: "second"),
            sourceAppBundleID: nil,
            copiedAt: .now,
            retentionPolicy: .forever)
        var edited = try await store.payload(for: first)
        edited.content = "second"

        await #expect(throws: (any Error).self) {
            try await store.updatePayload(itemID: try #require(first.id), payload: edited)
        }

        #expect(try await store.history(limit: 10).map(\.content).sorted() == ["first", "second"])
    }

    @Test
    func concurrentRecopiesKeepRichRepresentationsAndLeaveNoOrphanAssets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardRepository(
            database: try AppDatabase.makeInMemory(),
            metadataLoader: EmptyMetadataLoader(),
            assetStore: FileClipboardAssetStore(directory: directory))
        let rich = ClipboardPayload(
            kind: .text,
            content: "concurrent formatted paste",
            representations: [
                ClipboardRepresentation(type: "public.rtf", data: Data([0, 1, 2, 3, 4]))
            ])

        async let richCopy = store.recordCopy(
            rich,
            sourceAppBundleID: "com.example.editor",
            copiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            retentionPolicy: .forever)
        async let plainCopy = store.recordCopy(
            ClipboardPayload(kind: .text, content: "concurrent formatted paste"),
            sourceAppBundleID: "com.example.editor",
            copiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            retentionPolicy: .forever)
        _ = try await (richCopy, plainCopy)

        let historyItems = try await store.history(limit: 10)
        let item = try #require(historyItems.first)
        let restored = try await store.payload(for: item)
        let assetFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(restored.representations == rich.representations)
        #expect(assetFiles == [item.assetPath].compactMap { $0 })
    }

    @Test
    func v3UpgradePreservesLegacyRowsMetadataForeignKeysAndSearchAndAcceptsNewKinds() async throws {
        let queue = try makePopulatedV3Database()
        try ClipboardDatabaseMigrator.migrate(queue)

        let legacyValues = try await queue.read { db -> (Int64, Int64, String, String?, String?, Date, Date, Date) in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM clipboard_items WHERE id = 47")
            else {
                throw NSError(domain: "ClipboardDataContractTests", code: 1)
            }
            return (
                row["id"],
                row["collectionID"],
                row["deduplicationKey"],
                row["title"],
                row["linkDescription"],
                row["firstCopiedAt"],
                row["lastCopiedAt"],
                row["expiresAt"])
        }
        #expect(legacyValues.0 == 47)
        #expect(legacyValues.1 == 31)
        #expect(legacyValues.2 == "link:https://legacy.example/path")
        #expect(legacyValues.3 == "LegacyTitleToken")
        #expect(legacyValues.4 == "LegacyDescriptionToken")
        #expect(legacyValues.5 == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(legacyValues.6 == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(legacyValues.7 == Date(timeIntervalSince1970: 1_700_086_500))
        let foreignKeyViolationCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? -1
        }
        #expect(foreignKeyViolationCount == 0)

        let assetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: assetDirectory) }
        let database = try AppDatabase(databaseWriter: queue)
        let store = ClipboardRepository(
            database: database,
            metadataLoader: EmptyMetadataLoader(),
            assetStore: FileClipboardAssetStore(directory: assetDirectory))

        let foundByLegacyFTS = try await store.search(query: "LegacyTitleToken", limit: 10)
        #expect(foundByLegacyFTS.compactMap(\.id) == [47])
        let preservedItems = try await store.fetchItems(
            query: ClipboardQuery(scope: .collection(31)),
            limit: 10,
            offset: 0)
        let preserved = try #require(preservedItems.first)
        #expect(preserved.id == 47)
        #expect(preserved.canonicalURL == "https://legacy.example/path")
        #expect(preserved.sourceAppBundleID == "com.example.legacy")
        #expect(preserved.isInHistory == false)

        let copiedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let image = ClipboardPayload(
            kind: .image,
            content: "image/png",
            representations: [ClipboardRepresentation(type: "public.png", data: Data([1, 2, 3]))])
        let file = ClipboardPayload(
            kind: .file,
            content: "legacy fixture file",
            files: [ClipboardFileReference(url: "file:///tmp/contract.pdf", name: "contract.pdf")])
        let color = ClipboardPayload(kind: .color, content: "#123ABC", colorHex: "#123ABC")
        for (index, payload) in [image, file, color].enumerated() {
            _ = try await store.recordCopy(
                payload,
                sourceAppBundleID: nil,
                copiedAt: copiedAt.addingTimeInterval(Double(index)),
                retentionPolicy: .forever)
        }
        let insertedKinds = Set(try await store.fetchItems(
            query: ClipboardQuery(scope: .all),
            limit: 10,
            offset: 0).map(\.kind))
        #expect(insertedKinds.isSuperset(of: [.image, .file, .color]))

        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO clipboard_items (
                            kind, content, deduplicationKey, firstCopiedAt, lastCopiedAt
                        ) VALUES ('unknown', 'bad', 'invalid-kind:test', ?, ?)
                        """,
                    arguments: [copiedAt, copiedAt])
            }
        }
    }

    @Test
    func manualCollectionAndCardOrderSurvivesRecopyAndUnpinRefreshesOnlyExpiredHistory() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = ClipboardRepository(database: database, metadataLoader: EmptyMetadataLoader())
        let copiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstCollection = try await store.createCollection(name: "First", createdAt: copiedAt)
        let secondCollection = try await store.createCollection(name: "Second", createdAt: copiedAt)
        let firstCollectionID = try #require(firstCollection.id)
        let secondCollectionID = try #require(secondCollection.id)
        let first = try #require(await store.recordCopy(
            ClipboardPayload(kind: .text, content: "order first"),
            sourceAppBundleID: nil,
            copiedAt: copiedAt,
            retentionPolicy: .oneDay))
        let second = try #require(await store.recordCopy(
            ClipboardPayload(kind: .text, content: "order second"),
            sourceAppBundleID: nil,
            copiedAt: copiedAt.addingTimeInterval(1),
            retentionPolicy: .forever))
        let third = try #require(await store.recordCopy(
            ClipboardPayload(kind: .text, content: "order third"),
            sourceAppBundleID: nil,
            copiedAt: copiedAt.addingTimeInterval(2),
            retentionPolicy: .forever))
        let firstID = try #require(first.id)
        let secondID = try #require(second.id)
        let thirdID = try #require(third.id)
        try await store.moveItems(
            ids: [firstID, secondID, thirdID],
            to: firstCollectionID,
            retentionPolicy: .forever,
            now: copiedAt)
        try await store.reorderItems(ids: [thirdID, firstID, secondID], collectionID: firstCollectionID)
        try await store.reorderCollections(ids: [secondCollectionID, firstCollectionID])

        let collectionOrder = try await store.collections().compactMap(\.id)
        #expect(collectionOrder == [secondCollectionID, firstCollectionID])
        _ = try await store.recordCopy(
            ClipboardPayload(kind: .text, content: "order first"),
            sourceAppBundleID: nil,
            copiedAt: copiedAt.addingTimeInterval(50),
            retentionPolicy: .forever)
        let orderedItems = try await store.collectionItems(collectionID: firstCollectionID, limit: 10)
        #expect(orderedItems.compactMap(\.id) == [thirdID, firstID, secondID])

        let now = copiedAt.addingTimeInterval(10 * 24 * 60 * 60)
        let expired = try #require(await store.recordCopy(
            ClipboardPayload(kind: .text, content: "expired unpin"),
            sourceAppBundleID: nil,
            copiedAt: copiedAt,
            retentionPolicy: .oneDay))
        let expiredID = try #require(expired.id)
        try await store.moveItems(
            ids: [expiredID],
            to: secondCollectionID,
            retentionPolicy: .oneDay,
            now: copiedAt)
        try await store.moveItems(
            ids: [expiredID],
            to: nil,
            retentionPolicy: .oneWeek,
            now: now)
        let restoredItems = try await store.fetchItems(
            query: ClipboardQuery(scope: .history, text: "expired unpin"),
            limit: 10,
            offset: 0)
        let restored = try #require(restoredItems.first)
        #expect(restored.id == expiredID)
        #expect(restored.lastCopiedAt == copiedAt)
        #expect(restored.expiresAt == ClipboardRetentionPolicy.oneWeek.expirationDate(relativeTo: now))
    }

    @Test
    @MainActor
    func attributedTextEditsRegenerateOriginalFormatsAndPreserveFontAttributes() throws {
        let boldText = NSMutableAttributedString(string: "bold")
        boldText.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 16),
            range: NSRange(location: 0, length: boldText.length))
        let rtf = try boldText.data(
            from: NSRange(location: 0, length: boldText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let html = try boldText.data(
            from: NSRange(location: 0, length: boldText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        let original = ClipboardPayload(
            kind: .text,
            content: "bold",
            representations: [
                ClipboardRepresentation(type: "public.rtf", data: rtf),
                ClipboardRepresentation(type: "public.html", data: html),
                ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("bold".utf8)),
                ClipboardRepresentation(type: "public.utf16-plain-text", data: Data([0, 98])),
                ClipboardRepresentation(type: "public.png", data: Data([8, 9]))
            ])

        let parsed = ClipboardTextFormatting.attributedText(from: original)
        let edited = NSMutableAttributedString(attributedString: parsed)
        edited.append(NSAttributedString(string: " updated"))
        let updated = try ClipboardTextFormatting.updatedPayload(
            original,
            text: edited,
            language: nil)

        #expect(updated.content == "bold updated")
        #expect(String(data: try #require(updated.representations.first {
            $0.type == "public.utf8-plain-text"
        }?.data), encoding: .utf8) == "bold updated")
        #expect(updated.representations.first { $0.type == "public.png" }?.data == Data([8, 9]))
        #expect(!updated.representations.contains { $0.type == "public.utf16-plain-text" })
        #expect(ClipboardTextFormatting.attributedText(from: ClipboardPayload(
            kind: .text,
            content: "canonical text",
            representations: [
                ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("stale text".utf8))
            ])).string == "canonical text")

        let updatedRTF = try #require(updated.representations.first { $0.type == "public.rtf" })
        let updatedHTML = try #require(updated.representations.first { $0.type == "public.html" })
        let fromRTF = ClipboardTextFormatting.attributedText(from: ClipboardPayload(
            kind: .text,
            content: updated.content,
            representations: [updatedRTF]))
        let fromHTML = ClipboardTextFormatting.attributedText(from: ClipboardPayload(
            kind: .text,
            content: updated.content,
            representations: [updatedHTML]))
        for attributed in [fromRTF, fromHTML] {
            let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
            #expect(attributed.string == "bold updated")
        }

        let textWithTrailingNewline = NSAttributedString(string: "bold updated\n")
        let htmlWithTrailingNewline = try textWithTrailingNewline.data(
            from: NSRange(location: 0, length: textWithTrailingNewline.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        let restoredTrailingNewline = ClipboardTextFormatting.attributedText(from: ClipboardPayload(
            kind: .text,
            content: textWithTrailingNewline.string,
            representations: [ClipboardRepresentation(type: "public.html", data: htmlWithTrailingNewline)]))
        #expect(restoredTrailingNewline.string == "bold updated\n")
    }

    @Test
    func legacyPlainTextUpdateDropsStaleTextRepresentations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardRepository(
            database: try AppDatabase.makeInMemory(),
            metadataLoader: EmptyMetadataLoader(),
            assetStore: FileClipboardAssetStore(directory: directory))
        let item = try #require(await store.recordCopy(
            ClipboardPayload(
                kind: .text,
                content: "old formatted text",
                representations: [
                    ClipboardRepresentation(type: "public.rtf", data: Data([1, 2, 3])),
                    ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("old formatted text".utf8)),
                    ClipboardRepresentation(type: "public.utf16-plain-text", data: Data([0, 111]))
                ]),
            sourceAppBundleID: nil,
            copiedAt: .now,
            retentionPolicy: .forever))
        try await store.updateText(
            itemID: try #require(item.id),
            content: "new plain text",
            language: nil)

        let historyItems = try await store.history(limit: 10)
        let updatedItem = try #require(historyItems.first)
        let updated = try await store.payload(for: updatedItem)
        #expect(updated.content == "new plain text")
        #expect(updated.representations.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test
    func classifierNormalizesHexAndKeepsCodeLanguageWithinSupportedSet() {
        #expect(ClipboardClassifier.normalizeColor("#a1B2c3") == "#A1B2C3")
        #expect(ClipboardClassifier.normalizeColor("blue") == nil)
        #expect(ClipboardClassifier.classify("#123456").kind == .color)
        #expect(ClipboardClassifier.classify("123ABC").kind == .color)
        #expect(ClipboardClassifier.classify("123456").kind == .text)

        let functionPayload = ClipboardClassifier.classify("func answer() -> Int {\n    let value = 42\n    return value\n}")
        #expect(functionPayload.kind == .code)
        #expect(functionPayload.codeLanguage == "Swift")
        #expect(functionPayload.deduplicationKey == "text:\(functionPayload.content)")

        let structPayload = ClipboardClassifier.classify("struct Example {\n    let value: Int\n}")
        #expect(structPayload.kind == .code)
        #expect(structPayload.codeLanguage == "Swift")
    }
}

private func makePopulatedV3Database() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE grdb_migrations (
                identifier TEXT NOT NULL PRIMARY KEY
            )
            """)
        try db.execute(sql: """
            INSERT INTO grdb_migrations(identifier) VALUES ('v1'), ('v2'), ('v3')
            """)
        try db.execute(sql: """
            CREATE TABLE clipboard_collections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE clipboard_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL CHECK(kind IN ('text', 'link')),
                content TEXT NOT NULL,
                deduplicationKey TEXT NOT NULL UNIQUE,
                canonicalURL TEXT,
                title TEXT,
                linkDescription TEXT,
                sourceAppBundleID TEXT,
                firstCopiedAt DATETIME NOT NULL,
                lastCopiedAt DATETIME NOT NULL,
                isInHistory BOOLEAN NOT NULL DEFAULT 1,
                collectionID INTEGER REFERENCES clipboard_collections(id) ON DELETE SET NULL,
                expiresAt DATETIME
            )
            """)
        try db.execute(sql: """
            CREATE INDEX clipboard_items_history_order
            ON clipboard_items(isInHistory, lastCopiedAt, id)
            """)
        try db.execute(sql: """
            CREATE INDEX clipboard_items_collection_order
            ON clipboard_items(collectionID, lastCopiedAt, id)
            """)
        try db.execute(sql: """
            CREATE INDEX clipboard_items_expiration
            ON clipboard_items(isInHistory, expiresAt)
            """)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE clipboard_items_fts
            USING fts5(content, title, linkDescription, tokenize='unicode61')
            """)
        try db.execute(sql: """
            CREATE TRIGGER clipboard_items_fts_insert
            AFTER INSERT ON clipboard_items BEGIN
                INSERT INTO clipboard_items_fts(rowid, content, title, linkDescription)
                VALUES (new.id, new.content, coalesce(new.title, ''), coalesce(new.linkDescription, ''));
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER clipboard_items_fts_update
            AFTER UPDATE OF content, title, linkDescription ON clipboard_items BEGIN
                DELETE FROM clipboard_items_fts WHERE rowid = old.id;
                INSERT INTO clipboard_items_fts(rowid, content, title, linkDescription)
                VALUES (new.id, new.content, coalesce(new.title, ''), coalesce(new.linkDescription, ''));
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER clipboard_items_fts_delete
            AFTER DELETE ON clipboard_items BEGIN
                DELETE FROM clipboard_items_fts WHERE rowid = old.id;
            END
            """)
        let copiedAt = Date(timeIntervalSince1970: 1_700_000_100)
        try db.execute(
            sql: "INSERT INTO clipboard_collections(id, name, createdAt) VALUES (31, ?, ?)",
            arguments: ["Legacy", Date(timeIntervalSince1970: 1_699_999_000)])
        try db.execute(
            sql: """
                INSERT INTO clipboard_items (
                    id, kind, content, deduplicationKey, canonicalURL, title, linkDescription,
                    sourceAppBundleID, firstCopiedAt, lastCopiedAt, isInHistory, collectionID, expiresAt
                ) VALUES (47, 'link', ?, ?, ?, ?, ?, ?, ?, ?, 0, 31, ?)
                """,
            arguments: [
                "https://legacy.example/path",
                "link:https://legacy.example/path",
                "https://legacy.example/path",
                "LegacyTitleToken",
                "LegacyDescriptionToken",
                "com.example.legacy",
                Date(timeIntervalSince1970: 1_700_000_000),
                copiedAt,
                Date(timeIntervalSince1970: 1_700_086_500)
            ])
    }
    return queue
}

private struct EmptyMetadataLoader: LinkMetadataLoading {
    func metadata(for url: URL) async throws -> ClipboardLinkMetadata? { nil }
}
