import Foundation

enum ClipboardTextNormalizer {
    static func acceptedContent(_ content: String?) -> String? {
        guard let content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return content
    }
}

@MainActor
protocol ClipboardPasteboardReading: AnyObject {
    var changeCount: Int { get }
    func stringContents() -> String?
    var sourceApplicationBundleIdentifier: String? { get }
}
