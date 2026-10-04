import Foundation
import GRDB

actor AppDatabase {
    private let writer: any DatabaseWriter

    init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(pool)
        writer = pool
    }

    init(databaseWriter: any DatabaseWriter) throws {
        try Self.migrator.migrate(databaseWriter)
        writer = databaseWriter
    }

    static func openDefault() throws -> AppDatabase {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("OpenPaste", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenPaste.sqlite")
        return try AppDatabase(path: databaseURL.path)
    }

    static func makeInMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try AppDatabase(databaseWriter: DatabaseQueue(configuration: configuration))
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clipboard_collections") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "clipboard_items") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("kind", .text).notNull()
                    .check(sql: "kind IN ('text', 'link')")
                table.column("content", .text).notNull()
                table.column("deduplicationKey", .text).notNull().unique()
                table.column("canonicalURL", .text)
                table.column("title", .text)
                table.column("linkDescription", .text)
                table.column("sourceAppBundleID", .text)
                table.column("firstCopiedAt", .datetime).notNull()
                table.column("lastCopiedAt", .datetime).notNull()
                table.column("isInHistory", .boolean).notNull().defaults(to: true)
                table.column("collectionID", .integer)
                    .references("clipboard_collections", onDelete: .setNull)
            }

            try db.create(
                index: "clipboard_items_history_order",
                on: "clipboard_items",
                columns: ["isInHistory", "lastCopiedAt", "id"])

            try db.create(
                index: "clipboard_items_collection_order",
                on: "clipboard_items",
                columns: ["collectionID", "lastCopiedAt", "id"])

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
        }

        migrator.registerMigration("v2") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_items_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_items_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_items_fts_delete")

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
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "clipboard_items") { table in
                table.add(column: "expiresAt", .datetime)
            }
            try db.create(
                index: "clipboard_items_expiration",
                on: "clipboard_items",
                columns: ["isInHistory", "expiresAt"])

            let legacyPolicy = ClipboardPreferences.retentionPolicy
            if legacyPolicy != .forever {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, lastCopiedAt FROM clipboard_items")
                for row in rows {
                    let itemID: Int64 = row["id"]
                    let copiedAt: Date = row["lastCopiedAt"]
                    guard let expiration = legacyPolicy.expirationDate(relativeTo: copiedAt) else {
                        continue
                    }
                    try db.execute(
                        sql: "UPDATE clipboard_items SET expiresAt = ? WHERE id = ?",
                        arguments: [expiration, itemID])
                }
            }
        }

        return migrator
    }

    func recordCopy(
        content: ClipboardContent,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy = .oneMonth
    ) async throws -> ClipboardItem {
        try await writer.write { db in
            let kind = content.kind.rawValue
            let sql = """
                INSERT INTO clipboard_items (
                    kind, content, deduplicationKey, canonicalURL,
                    firstCopiedAt, lastCopiedAt, sourceAppBundleID, expiresAt, isInHistory
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(deduplicationKey) DO UPDATE SET
                    content = excluded.content,
                    canonicalURL = excluded.canonicalURL,
                    lastCopiedAt = excluded.lastCopiedAt,
                    sourceAppBundleID = excluded.sourceAppBundleID,
                    expiresAt = excluded.expiresAt,
                    isInHistory = 1
                RETURNING *
                """
            guard let item = try ClipboardItem.fetchOne(
                db,
                sql: sql,
                arguments: [
                    kind,
                    content.value,
                    content.deduplicationKey,
                    content.canonicalURL,
                    copiedAt,
                    copiedAt,
                    sourceAppBundleID,
                    retentionPolicy.expirationDate(relativeTo: copiedAt)
                ])
            else {
                throw DatabaseError(resultCode: .SQLITE_NOTFOUND)
            }
            return item
        }
    }

    func updateLinkMetadata(itemID: Int64, metadata: ClipboardLinkMetadata) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET title = ?, linkDescription = ?
                    WHERE id = ? AND kind = 'link'
                    """,
                arguments: [metadata.title, metadata.description, itemID])
        }
    }

    func history(limit: Int) async throws -> [ClipboardItem] {
        try await writer.read { db in
            try ClipboardItem.fetchAll(
                db,
                sql: """
                    SELECT * FROM clipboard_items
                    WHERE isInHistory = 1
                    ORDER BY lastCopiedAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [max(1, min(limit, 500))])
        }
    }

    func collectionItems(collectionID: Int64, limit: Int) async throws -> [ClipboardItem] {
        try await writer.read { db in
            try ClipboardItem.fetchAll(
                db,
                sql: """
                    SELECT * FROM clipboard_items
                    WHERE collectionID = ?
                    ORDER BY lastCopiedAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [collectionID, max(1, min(limit, 500))])
        }
    }

    func collections() async throws -> [ClipboardCollection] {
        try await writer.read { db in
            try ClipboardCollection.fetchAll(
                db,
                sql: "SELECT * FROM clipboard_collections ORDER BY name COLLATE NOCASE, id")
        }
    }

    func observeCollections() -> AsyncValueObservation<[ClipboardCollection]> {
        let writer = self.writer
        let observation = ValueObservation.tracking { db in
            try ClipboardCollection.fetchAll(
                db,
                sql: "SELECT * FROM clipboard_collections ORDER BY name COLLATE NOCASE, id")
        }
        return observation.values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    func search(query: String, limit: Int, offset: Int) async throws -> [ClipboardItem] {
        let matchExpression = Self.ftsMatchExpression(query)
        guard !matchExpression.isEmpty else { return [] }

        return try await writer.read { db in
            try ClipboardItem.fetchAll(
                db,
                sql: """
                    SELECT clipboard_items.*
                    FROM clipboard_items
                    JOIN clipboard_items_fts
                        ON clipboard_items_fts.rowid = clipboard_items.id
                    WHERE clipboard_items_fts MATCH ?
                    ORDER BY bm25(clipboard_items_fts),
                             clipboard_items.lastCopiedAt DESC,
                             clipboard_items.id DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [
                    matchExpression,
                    max(1, min(limit, 200)),
                    max(0, offset)
                ])
        }
    }

    func createCollection(name: String, createdAt: Date) async throws -> ClipboardCollection {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ClipboardStoreError.emptyCollectionName
        }

        return try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO clipboard_collections(name, createdAt) VALUES (?, ?)",
                arguments: [trimmedName, createdAt])
            let id = db.lastInsertedRowID
            guard let collection = try ClipboardCollection.fetchOne(
                db,
                sql: "SELECT * FROM clipboard_collections WHERE id = ?",
                arguments: [id])
            else {
                throw DatabaseError(resultCode: .SQLITE_NOTFOUND)
            }
            return collection
        }
    }

    func moveToCollection(itemID: Int64, collectionID: Int64?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET collectionID = ? WHERE id = ?",
                arguments: [collectionID, itemID])
            try Self.deleteOrphanedItems(db)
        }
    }

    func removeFromHistory(itemID: Int64) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET isInHistory = 0 WHERE id = ?",
                arguments: [itemID])
            try Self.deleteOrphanedItems(db)
        }
    }

    func deletePermanently(itemID: Int64) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [itemID])
        }
    }

    func removeCollection(collectionID: Int64) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM clipboard_collections WHERE id = ?",
                arguments: [collectionID])
            try Self.deleteOrphanedItems(db)
        }
    }

    func clearHistory() async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE clipboard_items SET isInHistory = 0 WHERE isInHistory = 1")
            try Self.deleteOrphanedItems(db)
        }
    }

    func pruneExpiredHistory(now: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET isInHistory = 0
                    WHERE isInHistory = 1 AND expiresAt IS NOT NULL AND expiresAt <= ?
                    """,
                arguments: [now])
            try Self.deleteOrphanedItems(db)
        }
    }

    func observeHistory(limit: Int) -> AsyncValueObservation<[ClipboardItem]> {
        let writer = self.writer
        let boundedLimit = max(1, min(limit, 500))
        let observation = ValueObservation.tracking { db in
            try ClipboardItem.fetchAll(
                db,
                sql: """
                    SELECT * FROM clipboard_items
                    WHERE isInHistory = 1
                    ORDER BY lastCopiedAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [boundedLimit])
        }
        return observation.values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    func observeCollection(
        collectionID: Int64,
        limit: Int
    ) -> AsyncValueObservation<[ClipboardItem]> {
        let writer = self.writer
        let boundedLimit = max(1, min(limit, 500))
        let observation = ValueObservation.tracking { db in
            try ClipboardItem.fetchAll(
                db,
                sql: """
                    SELECT * FROM clipboard_items
                    WHERE collectionID = ?
                    ORDER BY lastCopiedAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [collectionID, boundedLimit])
        }
        return observation.values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    #if DEBUG
    func seedBenchmarkData(count: Int, at date: Date) async throws {
        guard count >= 0 else { return }
        try await writer.write { db in
            for index in 0..<count {
                let suffix = index == count - 1 ? " raremarker" : ""
                try db.execute(
                    sql: """
                        INSERT INTO clipboard_items (
                            kind, content, deduplicationKey,
                            firstCopiedAt, lastCopiedAt, isInHistory
                        )
                        VALUES ('text', ?, ?, ?, ?, 1)
                        """,
                    arguments: [
                        "Copied item \(index) commonneedle\(suffix)",
                        "benchmark:\(index)",
                        date,
                        date
                    ])
            }
        }
    }
    #endif

    private static func ftsMatchExpression(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace)
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " AND ")
    }

    private static func deleteOrphanedItems(_ db: Database) throws {
        try db.execute(
            sql: "DELETE FROM clipboard_items WHERE isInHistory = 0 AND collectionID IS NULL")
    }
}
