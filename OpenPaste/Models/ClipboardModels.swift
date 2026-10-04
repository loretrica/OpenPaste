import Foundation
import GRDB

enum ClipboardItemKind: String, CaseIterable, Codable, Sendable {
    case text
    case link
}

enum ClipboardContent: Sendable, Equatable {
    case text(String)
    case link(rawURL: String, canonicalURL: String)

    var kind: ClipboardItemKind {
        switch self {
        case .text: .text
        case .link: .link
        }
    }

    var value: String {
        switch self {
        case let .text(value): value
        case let .link(rawURL, _): rawURL
        }
    }

    var canonicalURL: String? {
        guard case let .link(_, canonicalURL) = self else { return nil }
        return canonicalURL
    }

    var deduplicationKey: String {
        switch self {
        case let .text(value):
            "text:\(value)"
        case let .link(_, canonicalURL):
            "link:\(canonicalURL)"
        }
    }

    static func classify(_ value: String) -> ClipboardContent {
        guard let canonicalURL = URLIdentity.canonicalize(value) else {
            return .text(value)
        }
        return .link(rawURL: value, canonicalURL: canonicalURL)
    }
}

enum URLIdentity {
    static func canonicalize(_ rawValue: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              !trimmedValue.contains(where: \.isWhitespace)
        else {
            return nil
        }

        components.scheme = scheme
        components.host = host.lowercased()

        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }

        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }

        return components.string
    }
}

struct ClipboardItem: Codable, FetchableRecord, Identifiable, Sendable, Equatable {
    var id: Int64?
    var kind: ClipboardItemKind
    var content: String
    var deduplicationKey: String
    var canonicalURL: String?
    var title: String?
    var linkDescription: String?
    var sourceAppBundleID: String?
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var isInHistory: Bool
    var collectionID: Int64?
}

struct ClipboardCollection: Codable, FetchableRecord, Identifiable, Sendable, Equatable {
    var id: Int64?
    var name: String
    var createdAt: Date
}

enum ClipboardRetentionPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    case oneDay
    case oneWeek
    case oneMonth
    case oneYear
    case forever

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneDay: "1 giorno"
        case .oneWeek: "1 settimana"
        case .oneMonth: "1 mese"
        case .oneYear: "1 anno"
        case .forever: "Per sempre"
        }
    }

    func cutoffDate(relativeTo date: Date) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        return switch self {
        case .oneDay:
            calendar.date(byAdding: .day, value: -1, to: date)
        case .oneWeek:
            calendar.date(byAdding: .day, value: -7, to: date)
        case .oneMonth:
            calendar.date(byAdding: .month, value: -1, to: date)
        case .oneYear:
            calendar.date(byAdding: .year, value: -1, to: date)
        case .forever:
            nil
        }
    }
}

struct ClipboardLinkMetadata: Sendable, Equatable {
    var title: String?
    var description: String?
}

struct ClipboardPreferences {
    private static let retentionPolicyKey = "clipboard.retentionPolicy"

    static var retentionPolicy: ClipboardRetentionPolicy {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: retentionPolicyKey),
                  let policy = ClipboardRetentionPolicy(rawValue: rawValue)
            else {
                return .oneMonth
            }
            return policy
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: retentionPolicyKey)
        }
    }
}
