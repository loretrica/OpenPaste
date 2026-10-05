import Foundation

protocol ClipboardAssetStore: Sendable {
    func save(_ payload: ClipboardPayload) async throws -> String
    func load(at relativePath: String) async throws -> ClipboardPayload
    func delete(at relativePath: String) async throws
}

actor FileClipboardAssetStore: ClipboardAssetStore {
    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directory = applicationSupport
                .appendingPathComponent("OpenPaste", isDirectory: true)
                .appendingPathComponent("Assets", isDirectory: true)
        }
    }

    func save(_ payload: ClipboardPayload) async throws -> String {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString.lowercased() + ".json"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
        return name
    }

    func load(at relativePath: String) async throws -> ClipboardPayload {
        let url = try fileURL(for: relativePath)
        return try JSONDecoder().decode(ClipboardPayload.self, from: Data(contentsOf: url))
    }

    func delete(at relativePath: String) async throws {
        let url = try fileURL(for: relativePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(for relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else { throw ClipboardAssetStoreError.invalidPath }
        return directory.appendingPathComponent(relativePath, isDirectory: false)
    }
}

enum ClipboardAssetStoreError: Error, Sendable {
    case invalidPath
    case missingAsset
}
