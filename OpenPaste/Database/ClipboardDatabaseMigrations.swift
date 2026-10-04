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

        return migrator
    }
}
