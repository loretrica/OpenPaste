import Foundation

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
