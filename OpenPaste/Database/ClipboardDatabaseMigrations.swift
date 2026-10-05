import Foundation
import GRDB

enum ClipboardDatabaseMigrator {
    static func migrate(_ writer: any DatabaseWriter) throws {
        try migrator.migrate(writer)
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

        migrator.registerMigration("v4") { db in
            try db.alter(table: "clipboard_collections") { table in
                table.add(column: "colorHex", .text).notNull().defaults(to: "#FF3B30")
                table.add(column: "sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                UPDATE clipboard_collections
                SET sortOrder = (
                    SELECT COUNT(*) FROM clipboard_collections AS earlier
                    WHERE earlier.name COLLATE NOCASE < clipboard_collections.name COLLATE NOCASE
                       OR (earlier.name COLLATE NOCASE = clipboard_collections.name COLLATE NOCASE
                           AND earlier.id < clipboard_collections.id)
                )
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_items_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_items_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_items_fts_delete")
            try db.execute(sql: "DROP INDEX IF EXISTS clipboard_items_history_order")
            try db.execute(sql: "DROP INDEX IF EXISTS clipboard_items_collection_order")
            try db.execute(sql: "DROP INDEX IF EXISTS clipboard_items_expiration")

            try db.create(table: "clipboard_items_v4") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("kind", .text).notNull()
                    .check(sql: "kind IN ('text', 'link', 'image', 'file', 'code', 'color')")
                table.column("content", .text).notNull()
                table.column("deduplicationKey", .text).notNull().unique()
                table.column("canonicalURL", .text)
                table.column("title", .text)
                table.column("linkDescription", .text)
                table.column("sourceAppBundleID", .text)
                table.column("firstCopiedAt", .datetime).notNull()
                table.column("lastCopiedAt", .datetime).notNull()
                table.column("expiresAt", .datetime)
                table.column("isInHistory", .boolean).notNull().defaults(to: true)
                table.column("collectionID", .integer)
                    .references("clipboard_collections", onDelete: .setNull)
                table.column("customTitle", .text)
                table.column("assetPath", .text)
                table.column("codeLanguage", .text)
                table.column("colorHex", .text)
                table.column("imageWidth", .integer)
                table.column("imageHeight", .integer)
                table.column("collectionSortOrder", .integer).notNull().defaults(to: 0)
                table.column("linkImageURL", .text)
                table.column("isUserClassified", .boolean).notNull().defaults(to: false)
            }

            try db.execute(sql: """
                INSERT INTO clipboard_items_v4 (
                    id, kind, content, deduplicationKey, canonicalURL, title, linkDescription,
                    sourceAppBundleID, firstCopiedAt, lastCopiedAt, expiresAt, isInHistory, collectionID
                )
                SELECT
                    id, kind, content, deduplicationKey, canonicalURL, title, linkDescription,
                    sourceAppBundleID, firstCopiedAt, lastCopiedAt, expiresAt, isInHistory, collectionID
                FROM clipboard_items
                """)
            try db.drop(table: "clipboard_items")
            try db.rename(table: "clipboard_items_v4", to: "clipboard_items")

            try db.create(
                index: "clipboard_items_history_order",
                on: "clipboard_items",
                columns: ["isInHistory", "lastCopiedAt", "id"])
            try db.create(
                index: "clipboard_items_collection_order",
                on: "clipboard_items",
                columns: ["collectionID", "collectionSortOrder", "lastCopiedAt", "id"])
            try db.create(
                index: "clipboard_items_expiration",
                on: "clipboard_items",
                columns: ["isInHistory", "expiresAt"])

            try db.drop(table: "clipboard_items_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clipboard_items_fts
                USING fts5(content, title, linkDescription, customTitle, codeLanguage, tokenize='unicode61')
                """)
            try db.execute(sql: """
                INSERT INTO clipboard_items_fts(rowid, content, title, linkDescription, customTitle, codeLanguage)
                SELECT id, content, coalesce(title, ''), coalesce(linkDescription, ''),
                       coalesce(customTitle, ''), coalesce(codeLanguage, '')
                FROM clipboard_items
                """)
            try db.execute(sql: """
                CREATE TRIGGER clipboard_items_fts_insert
                AFTER INSERT ON clipboard_items BEGIN
                    INSERT INTO clipboard_items_fts(rowid, content, title, linkDescription, customTitle, codeLanguage)
                    VALUES (new.id, new.content, coalesce(new.title, ''), coalesce(new.linkDescription, ''),
                            coalesce(new.customTitle, ''), coalesce(new.codeLanguage, ''));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER clipboard_items_fts_update
                AFTER UPDATE OF content, title, linkDescription, customTitle, codeLanguage ON clipboard_items BEGIN
                    DELETE FROM clipboard_items_fts WHERE rowid = old.id;
                    INSERT INTO clipboard_items_fts(rowid, content, title, linkDescription, customTitle, codeLanguage)
                    VALUES (new.id, new.content, coalesce(new.title, ''), coalesce(new.linkDescription, ''),
                            coalesce(new.customTitle, ''), coalesce(new.codeLanguage, ''));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER clipboard_items_fts_delete
                AFTER DELETE ON clipboard_items BEGIN
                    DELETE FROM clipboard_items_fts WHERE rowid = old.id;
                END
                """)
        }

        return migrator
    }
}
