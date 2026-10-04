import Foundation
import GRDB

actor AppDatabase {
    private let writer: any DatabaseWriter

    init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        try ClipboardDatabaseMigrator.migrate(pool)
        writer = pool
    }

    init(databaseWriter: any DatabaseWriter) throws {
        try ClipboardDatabaseMigrator.migrate(databaseWriter)
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

    func read<T: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await writer.read(fetch)
    }

    func write<T: Sendable>(
        _ update: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await writer.write(update)
    }

    func observe<T: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> AsyncValueObservation<T> {
        ValueObservation.tracking(fetch)
            .values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }
}
