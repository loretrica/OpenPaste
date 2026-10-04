import Foundation
import GRDB

extension AppDatabase {
    func recordCopy(
        content: ClipboardContent,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy = .oneMonth
    ) async throws -> ClipboardItem {
        try await write { db in
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
        try await write { db in
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
        try await read { db in
            try Self.fetchHistory(in: db, limit: limit)
        }
    }

    func collectionItems(collectionID: Int64, limit: Int) async throws -> [ClipboardItem] {
        try await read { db in
            try Self.fetchCollectionItems(in: db, collectionID: collectionID, limit: limit)
        }
    }

    func collections() async throws -> [ClipboardCollection] {
        try await read { db in
            try Self.fetchCollections(in: db)
        }
    }

    func observeCollections() -> AsyncValueObservation<[ClipboardCollection]> {
        observe { db in
            try Self.fetchCollections(in: db)
        }
    }

    func search(query: String, limit: Int, offset: Int) async throws -> [ClipboardItem] {
        let matchExpression = Self.ftsMatchExpression(query)
        guard !matchExpression.isEmpty else { return [] }

        return try await read { db in
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
                    Self.boundedLimit(limit, maximum: 200),
                    max(0, offset)
                ])
        }
    }

    func createCollection(name: String, createdAt: Date) async throws -> ClipboardCollection {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ClipboardStoreError.emptyCollectionName
        }

        return try await write { db in
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
        try await write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET collectionID = ? WHERE id = ?",
                arguments: [collectionID, itemID])
            try Self.deleteOrphanedItems(db)
        }
    }

    func removeFromHistory(itemID: Int64) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET isInHistory = 0 WHERE id = ?",
                arguments: [itemID])
            try Self.deleteOrphanedItems(db)
        }
    }

    func deletePermanently(itemID: Int64) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [itemID])
        }
    }

    func removeCollection(collectionID: Int64) async throws {
        try await write { db in
            try db.execute(
                sql: "DELETE FROM clipboard_collections WHERE id = ?",
                arguments: [collectionID])
            try Self.deleteOrphanedItems(db)
        }
    }

    func clearHistory() async throws {
        try await write { db in
            try db.execute(sql: "UPDATE clipboard_items SET isInHistory = 0 WHERE isInHistory = 1")
            try Self.deleteOrphanedItems(db)
        }
    }

    func pruneExpiredHistory(now: Date) async throws {
        try await write { db in
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
        observe { db in
            try Self.fetchHistory(in: db, limit: limit)
        }
    }

    func observeCollection(
        collectionID: Int64,
        limit: Int
    ) -> AsyncValueObservation<[ClipboardItem]> {
        observe { db in
            try Self.fetchCollectionItems(in: db, collectionID: collectionID, limit: limit)
        }
    }

    #if DEBUG
    func seedBenchmarkData(count: Int, at date: Date) async throws {
        guard count >= 0 else { return }
        try await write { db in
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

    private static func fetchHistory(in db: Database, limit: Int) throws -> [ClipboardItem] {
        try ClipboardItem.fetchAll(
            db,
            sql: """
                SELECT * FROM clipboard_items
                WHERE isInHistory = 1
                ORDER BY lastCopiedAt DESC, id DESC
                LIMIT ?
                """,
            arguments: [boundedLimit(limit)])
    }

    private static func fetchCollectionItems(
        in db: Database,
        collectionID: Int64,
        limit: Int
    ) throws -> [ClipboardItem] {
        try ClipboardItem.fetchAll(
            db,
            sql: """
                SELECT * FROM clipboard_items
                WHERE collectionID = ?
                ORDER BY lastCopiedAt DESC, id DESC
                LIMIT ?
                """,
            arguments: [collectionID, boundedLimit(limit)])
    }

    private static func fetchCollections(in db: Database) throws -> [ClipboardCollection] {
        try ClipboardCollection.fetchAll(
            db,
            sql: "SELECT * FROM clipboard_collections ORDER BY name COLLATE NOCASE, id")
    }

    private static func boundedLimit(_ limit: Int, maximum: Int = 500) -> Int {
        max(1, min(limit, maximum))
    }

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
