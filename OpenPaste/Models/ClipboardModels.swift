import Foundation
import GRDB

enum ClipboardItemKind: String, CaseIterable, Codable, Sendable {
    case text
    case link
    case image
    case file
    case code
    case color
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
    var expiresAt: Date?
    var isInHistory: Bool
    var collectionID: Int64?
    var customTitle: String? = nil
    var assetPath: String? = nil
    var codeLanguage: String? = nil
    var colorHex: String? = nil
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
    var collectionSortOrder: Int = 0
    var linkImageURL: String? = nil
    var isUserClassified: Bool = false
}

struct ClipboardCollection: Codable, FetchableRecord, Identifiable, Sendable, Equatable {
    var id: Int64?
    var name: String
    var createdAt: Date
    var colorHex: String = "#FF3B30"
    var sortOrder: Int = 0
}

enum ClipboardListScope: Sendable, Equatable {
    case history
    case collection(Int64)
    case all
}

struct ClipboardFilter: Sendable, Equatable {
    var kind: ClipboardItemKind? = nil
    var sourceAppBundleID: String? = nil
    var fromDate: Date? = nil
    var toDate: Date? = nil

    var isEmpty: Bool {
        kind == nil && sourceAppBundleID == nil && fromDate == nil && toDate == nil
    }

    init(
        kind: ClipboardItemKind? = nil,
        sourceAppBundleID: String? = nil,
        fromDate: Date? = nil,
        toDate: Date? = nil
    ) {
        self.kind = kind
        self.sourceAppBundleID = sourceAppBundleID
        self.fromDate = fromDate
        self.toDate = toDate
    }
}

struct ClipboardQuery: Sendable, Equatable {
    var scope: ClipboardListScope
    var text: String
    var filter: ClipboardFilter

    init(
        scope: ClipboardListScope = .history,
        text: String = "",
        filter: ClipboardFilter = .init()
    ) {
        self.scope = scope
        self.text = text
        self.filter = filter
    }
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
        adjustedDate(relativeTo: date, direction: -1)
    }

    func expirationDate(relativeTo date: Date) -> Date? {
        adjustedDate(relativeTo: date, direction: 1)
    }

    private func adjustedDate(relativeTo date: Date, direction: Int) -> Date? {
        let componentAndValue: (Calendar.Component, Int)? = switch self {
        case .oneDay: (.day, 1)
        case .oneWeek: (.day, 7)
        case .oneMonth: (.month, 1)
        case .oneYear: (.year, 1)
        case .forever: nil
        }
        guard let (component, value) = componentAndValue else { return nil }
        return Calendar(identifier: .gregorian).date(
            byAdding: component,
            value: value * direction,
            to: date)
    }
}

struct ClipboardLinkMetadata: Sendable, Equatable {
    var title: String?
    var description: String?
    var imageURL: String? = nil
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
