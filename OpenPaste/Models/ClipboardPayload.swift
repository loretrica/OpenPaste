import Foundation

/// Public pasteboard representations captured at one change count.
struct ClipboardRepresentation: Codable, Equatable, Sendable {
    var type: String
    var data: Data
}

struct ClipboardFileReference: Codable, Equatable, Sendable {
    var url: String
    var bookmark: Data?
    var name: String

    init(url: String, bookmark: Data? = nil, name: String? = nil) {
        self.url = url
        self.bookmark = bookmark
        self.name = name ?? URL(string: url)?.lastPathComponent ?? url
    }

    func resolvedURL() -> URL? {
        if let bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale) {
                return resolved
            }
        }
        return URL(string: url)
    }
}

/// Binary representations live in the asset store, never in clipboard_items.
struct ClipboardPayload: Codable, Equatable, Sendable {
    var kind: ClipboardItemKind
    var content: String
    var representations: [ClipboardRepresentation] = []
    var files: [ClipboardFileReference] = []
    var codeLanguage: String?
    var colorHex: String?
    var imageWidth: Int?
    var imageHeight: Int?

    static func text(_ content: String) -> ClipboardPayload {
        ClipboardClassifier.classify(content)
    }

    static func restoring(_ item: ClipboardItem) -> ClipboardPayload {
        ClipboardPayload(
            kind: item.kind,
            content: item.content,
            codeLanguage: item.codeLanguage,
            colorHex: item.colorHex,
            imageWidth: item.imageWidth,
            imageHeight: item.imageHeight)
    }
}
