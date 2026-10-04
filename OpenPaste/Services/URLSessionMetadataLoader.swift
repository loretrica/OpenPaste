import Foundation

actor URLSessionMetadataLoader: LinkMetadataLoading {
    private let session: URLSession
    private let maximumResponseSize = 1_000_000

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func metadata(for url: URL) async throws -> ClipboardLinkMetadata? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              !isLocalHost(host)
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("OpenPaste/1.0", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url.map({ finalURL in
                  ["http", "https"].contains(finalURL.scheme?.lowercased() ?? "")
                      && finalURL.host.map { !isLocalHost($0) } == true
              }) == true,
              let mimeType = response.mimeType?.lowercased(),
              mimeType.contains("html"),
              response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(maximumResponseSize)
        else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(min(maximumResponseSize, 32_768))
        for try await byte in bytes {
            guard data.count < maximumResponseSize else { return nil }
            data.append(byte)
        }

        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let title = Self.title(in: html)
        let description = Self.description(in: html)
        guard title != nil || description != nil else { return nil }
        return ClipboardLinkMetadata(title: title, description: description)
    }

    private func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        let isPrivateIPv4: Bool
        if octets.count == 4 {
            let first = octets[0]
            let second = octets[1]
            isPrivateIPv4 = first == 0
                || first == 10
                || first == 127
                || (first == 169 && second == 254)
                || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168)
                || first >= 224
        } else {
            isPrivateIPv4 = false
        }

        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".home")
            || host.hasSuffix(".home.arpa")
            || host == "0.0.0.0"
            || host == "::1"
            || host.hasPrefix("[::1]")
            || (host.contains(":") && (
                host.hasPrefix("fc")
                    || host.hasPrefix("fd")
                    || host.hasPrefix("fe80:")
            ))
            || isPrivateIPv4
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
