import Foundation

enum MetadataURLPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              !isLocalHost(host)
        else {
            return false
        }
        return true
    }

    static func accepts(_ response: HTTPURLResponse, maximumResponseSize: Int) -> Bool {
        guard (200..<300).contains(response.statusCode),
              let finalURL = response.url,
              allows(finalURL),
              let mimeType = response.mimeType?.lowercased(),
              mimeType.contains("html")
        else {
            return false
        }

        return response.expectedContentLength < 0
            || response.expectedContentLength <= Int64(maximumResponseSize)
    }

    private static func isLocalHost(_ host: String) -> Bool {
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
}
