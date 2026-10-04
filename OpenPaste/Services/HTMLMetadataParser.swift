import Foundation

enum HTMLMetadataParser {
    static func parse(_ html: String) -> ClipboardLinkMetadata? {
        let title = title(in: html)
        let description = description(in: html)
        guard title != nil || description != nil else { return nil }
        return ClipboardLinkMetadata(title: title, description: description)
    }

    private static func title(in html: String) -> String? {
        guard let value = firstCapture(
            pattern: "(?is)<title\\b[^>]*>(.*?)</title>",
            in: html)
        else {
            return nil
        }
        return normalizedText(value)
    }

    private static func description(in html: String) -> String? {
        let pattern = "(?is)<meta\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)

        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let attributes = attributes(in: String(html[tagRange]))
            let name = (attributes["name"] ?? attributes["property"] ?? "").lowercased()
            guard name == "description" || name == "og:description" else { continue }
            if let content = attributes["content"] {
                return normalizedText(content)
            }
        }
        return nil
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([a-zA-Z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(tag.startIndex..., in: tag)
        var result: [String: String] = [:]

        for match in regex.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = String(tag[nameRange]).lowercased()
            let valueRange = (2...4).compactMap { Range(match.range(at: $0), in: tag) }.first
            if let valueRange {
                result[name] = String(tag[valueRange])
            }
        }
        return result
    }

    private static func firstCapture(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let captureRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[captureRange])
    }

    private static func normalizedText(_ value: String) -> String? {
        let withoutTags = value.replacingOccurrences(
            of: "(?is)<[^>]+>",
            with: " ",
            options: .regularExpression)
        let decoded = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        let normalized = decoded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
