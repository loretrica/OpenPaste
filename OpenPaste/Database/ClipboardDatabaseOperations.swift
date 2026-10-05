import Foundation
import GRDB

extension AppDatabase {
    func recordCopy(
        content: ClipboardContent,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy = .oneMonth
    ) async throws -> ClipboardItem {
        let payload = switch content {
        case let .text(value):
            ClipboardPayload(kind: .text, content: value)
        case let .link(rawURL, _):
            ClipboardPayload(kind: .link, content: rawURL)
        }
        return try await recordCopy(
            payload: payload,
            assetPath: nil,
            sourceAppBundleID: sourceAppBundleID,
            copiedAt: copiedAt,
            retentionPolicy: retentionPolicy)
    }

    func item(deduplicationKey: String) async throws -> ClipboardItem? {
        try await read { db in
            try ClipboardItem.fetchOne(
                db,
                sql: "SELECT * FROM clipboard_items WHERE deduplicationKey = ?",
                arguments: [deduplicationKey])
        }
    }

    func item(id: Int64) async throws -> ClipboardItem? {
        try await read { db in
            try ClipboardItem.fetchOne(
                db,
                sql: "SELECT * FROM clipboard_items WHERE id = ?",
                arguments: [id])
        }
    }

    func assetPaths() async throws -> [String] {
        try await read { db in
            try String.fetchAll(db, sql: "SELECT assetPath FROM clipboard_items WHERE assetPath IS NOT NULL")
        }
    }

    func recordCopy(
        payload: ClipboardPayload,
        assetPath: String?,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy
    ) async throws -> ClipboardItem {
        try await write { db in
            let sql = """
                INSERT INTO clipboard_items (
                    kind, content, deduplicationKey, canonicalURL, codeLanguage, colorHex,
                    imageWidth, imageHeight, assetPath, firstCopiedAt, lastCopiedAt,
                    sourceAppBundleID, expiresAt, isInHistory
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(deduplicationKey) DO UPDATE SET
                    kind = CASE WHEN clipboard_items.isUserClassified = 1
                                THEN clipboard_items.kind ELSE excluded.kind END,
                    content = excluded.content,
                    canonicalURL = excluded.canonicalURL,
                    codeLanguage = CASE WHEN clipboard_items.isUserClassified = 1
                                        THEN clipboard_items.codeLanguage ELSE excluded.codeLanguage END,
                    colorHex = CASE WHEN clipboard_items.isUserClassified = 1
                                    THEN clipboard_items.colorHex ELSE excluded.colorHex END,
                    imageWidth = excluded.imageWidth,
                    imageHeight = excluded.imageHeight,
                    assetPath = excluded.assetPath,
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
                    payload.kind.rawValue,
                    payload.content,
                    payload.deduplicationKey,
                    payload.canonicalURL,
                    payload.codeLanguage,
                    payload.colorHex,
                    payload.imageWidth,
                    payload.imageHeight,
                    assetPath,
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
                    SET title = ?, linkDescription = ?, linkImageURL = ?
                    WHERE id = ? AND kind = 'link'
                    """,
                arguments: [metadata.title, metadata.description, metadata.imageURL, itemID])
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

    func sourceApplicationBundleIDs() async throws -> [String] {
        try await read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT sourceAppBundleID
                    FROM clipboard_items
                    WHERE sourceAppBundleID IS NOT NULL
                      AND (isInHistory = 1 OR collectionID IS NOT NULL)
                    ORDER BY sourceAppBundleID COLLATE NOCASE
                    """)
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
                    max(0, limit),
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
            try db.execute(
                sql: """
                    DELETE FROM clipboard_items
                    WHERE id = ? AND isInHistory = 0 AND collectionID IS NULL
                    """,
                arguments: [itemID])
        }
    }

    func removeFromHistory(itemID: Int64) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET isInHistory = 0 WHERE id = ?",
                arguments: [itemID])
            try db.execute(
                sql: """
                    DELETE FROM clipboard_items
                    WHERE id = ? AND isInHistory = 0 AND collectionID IS NULL
                    """,
                arguments: [itemID])
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

    func fetchItems(query: ClipboardQuery, limit: Int, offset: Int) async throws -> [ClipboardItem] {
        try await read { db in
            try Self.fetchItems(in: db, query: query, limit: limit, offset: offset)
        }
    }

    func observeItems(query: ClipboardQuery, limit: Int) -> AsyncValueObservation<[ClipboardItem]> {
        observe { db in
            try Self.fetchItems(in: db, query: query, limit: limit, offset: 0)
        }
    }

    func updateCollection(collectionID: Int64, name: String, colorHex: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ClipboardStoreError.emptyCollectionName }
        guard let normalizedColor = ClipboardClassifier.normalizeColor(colorHex) else {
            throw ClipboardStoreError.invalidColor
        }
        try await write { db in
            try db.execute(
                sql: "UPDATE clipboard_collections SET name = ?, colorHex = ? WHERE id = ?",
                arguments: [trimmedName, normalizedColor, collectionID])
        }
    }

    func reorderCollections(ids: [Int64]) async throws {
        try await write { db in
            for (order, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE clipboard_collections SET sortOrder = ? WHERE id = ?",
                    arguments: [order, id])
            }
        }
    }

    func reorderItems(ids: [Int64], collectionID: Int64) async throws {
        try await write { db in
            for (order, id) in ids.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE clipboard_items SET collectionSortOrder = ?
                        WHERE id = ? AND collectionID = ?
                        """,
                    arguments: [order, id, collectionID])
            }
        }
    }

    func renameItem(itemID: Int64, title: String?) async throws {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET customTitle = ? WHERE id = ?",
                arguments: [trimmedTitle?.isEmpty == true ? nil : trimmedTitle, itemID])
        }
    }

    func updatePayload(
        itemID: Int64,
        payload: ClipboardPayload,
        assetPath: String?
    ) async throws -> String? {
        let oldAssetPath = try await item(id: itemID)?.assetPath
        try await write { db in
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET kind = ?, content = ?, deduplicationKey = ?, canonicalURL = ?,
                        codeLanguage = ?, colorHex = ?, imageWidth = ?, imageHeight = ?,
                        assetPath = ?, isUserClassified = 1
                    WHERE id = ?
                    """,
                arguments: [
                    payload.kind.rawValue,
                    payload.content,
                    payload.deduplicationKey,
                    payload.canonicalURL,
                    ClipboardClassifier.normalizeCodeLanguage(payload.codeLanguage),
                    ClipboardClassifier.normalizeColor(payload.colorHex ?? ""),
                    payload.imageWidth,
                    payload.imageHeight,
                    assetPath,
                    itemID
                ])
        }
        return oldAssetPath
    }

    func updateText(itemID: Int64, content: String, language: String?) async throws {
        let kind: ClipboardItemKind = language == nil ? .text : .code
        try await write { db in
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET content = ?, deduplicationKey = ?, kind = ?, codeLanguage = ?,
                        isUserClassified = 1
                    WHERE id = ?
                    """,
                arguments: [
                    content,
                    "text:\(content)",
                    kind.rawValue,
                    language,
                    itemID
                ])
        }
    }

    func setItemKind(itemID: Int64, kind: ClipboardItemKind, language: String?) async throws {
        try await write { db in
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET kind = ?, codeLanguage = ?, isUserClassified = 1
                    WHERE id = ?
                    """,
                arguments: [kind.rawValue, kind == .code ? language : nil, itemID])
        }
    }

    func moveItems(
        ids: [Int64],
        to collectionID: Int64?,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) async throws {
        try await write { db in
            let expiry = retentionPolicy.expirationDate(relativeTo: now)
            for (order, id) in ids.enumerated() {
                if let collectionID {
                    try db.execute(
                        sql: """
                            UPDATE clipboard_items
                            SET collectionID = ?, collectionSortOrder = ?
                            WHERE id = ?
                            """,
                        arguments: [collectionID, order, id])
                } else {
                    try db.execute(
                        sql: """
                            UPDATE clipboard_items
                            SET collectionID = NULL, isInHistory = 1, collectionSortOrder = 0,
                                expiresAt = CASE
                                    WHEN expiresAt IS NOT NULL AND expiresAt <= ? THEN ?
                                    ELSE expiresAt
                                END
                            WHERE id = ?
                            """,
                        arguments: [now, expiry, id])
                }
            }
            try Self.deleteOrphanedItems(db)
        }
    }

    func deleteCollectionPreservingItems(
        collectionID: Int64,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) async throws {
        try await write { db in
            let expiry = retentionPolicy.expirationDate(relativeTo: now)
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET collectionID = NULL, isInHistory = 1, collectionSortOrder = 0,
                        expiresAt = CASE
                            WHEN expiresAt IS NOT NULL AND expiresAt <= ? THEN ?
                            ELSE expiresAt
                        END
                    WHERE collectionID = ?
                    """,
                arguments: [now, expiry, collectionID])
            try db.execute(
                sql: "DELETE FROM clipboard_collections WHERE id = ?",
                arguments: [collectionID])
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

    private static func fetchItems(
        in db: Database,
        query: ClipboardQuery,
        limit: Int,
        offset: Int
    ) throws -> [ClipboardItem] {
        var sql = "SELECT clipboard_items.* FROM clipboard_items"
        var clauses: [String] = []
        var arguments = [(any DatabaseValueConvertible)?]()
        let hasText = !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasText {
            let matchExpression = ftsMatchExpression(query.text)
            guard !matchExpression.isEmpty else { return [] }
            sql += " JOIN clipboard_items_fts ON clipboard_items_fts.rowid = clipboard_items.id"
            clauses.append("clipboard_items_fts MATCH ?")
            arguments.append(matchExpression)
        }

        switch query.scope {
        case .history:
            clauses.append("clipboard_items.isInHistory = 1")
        case let .collection(collectionID):
            clauses.append("clipboard_items.collectionID = ?")
            arguments.append(collectionID)
        case .all:
            break
        }

        if let kind = query.filter.kind {
            clauses.append("clipboard_items.kind = ?")
            arguments.append(kind.rawValue)
        }
        if let sourceAppBundleID = query.filter.sourceAppBundleID {
            clauses.append("clipboard_items.sourceAppBundleID = ?")
            arguments.append(sourceAppBundleID)
        }
        if let fromDate = query.filter.fromDate {
            clauses.append("clipboard_items.lastCopiedAt >= ?")
            arguments.append(fromDate)
        }
        if let toDate = query.filter.toDate {
            clauses.append("clipboard_items.lastCopiedAt <= ?")
            arguments.append(toDate)
        }

        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        if case .collection = query.scope {
            sql += " ORDER BY clipboard_items.collectionSortOrder ASC, clipboard_items.lastCopiedAt DESC, clipboard_items.id DESC"
        } else if hasText {
            sql += " ORDER BY bm25(clipboard_items_fts), clipboard_items.lastCopiedAt DESC, clipboard_items.id DESC"
        } else {
            sql += " ORDER BY clipboard_items.lastCopiedAt DESC, clipboard_items.id DESC"
        }
        sql += " LIMIT ? OFFSET ?"
        arguments.append(max(0, limit))
        arguments.append(max(0, offset))

        return try ClipboardItem.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments(arguments))
    }

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
                ORDER BY collectionSortOrder ASC, lastCopiedAt DESC, id DESC
                LIMIT ?
                """,
            arguments: [collectionID, boundedLimit(limit)])
    }

    private static func fetchCollections(in db: Database) throws -> [ClipboardCollection] {
        try ClipboardCollection.fetchAll(
            db,
            sql: "SELECT * FROM clipboard_collections ORDER BY sortOrder ASC, id")
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
