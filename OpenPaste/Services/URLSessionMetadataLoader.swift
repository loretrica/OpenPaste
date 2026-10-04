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
        guard MetadataURLPolicy.allows(url) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("OpenPaste/1.0", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              MetadataURLPolicy.accepts(response, maximumResponseSize: maximumResponseSize)
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
        return HTMLMetadataParser.parse(html)
    }
}
