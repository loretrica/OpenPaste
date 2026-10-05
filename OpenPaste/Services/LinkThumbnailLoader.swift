import Foundation
import CryptoKit
import ImageIO

/// Redirects must obey the same policy as the original request.
final class MetadataSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(MetadataURLPolicy.allows) == true ? request : nil)
    }
}

actor LinkThumbnailLoader {
    static let shared = LinkThumbnailLoader()
    private let session: URLSession
    private let cacheDirectory: URL
    private var pending: [URL: Task<Data?, Never>] = [:]
    private static let maximumBytes = 5_000_000

    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenPaste/LinkPreviews", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(
            configuration: configuration,
            delegate: MetadataSessionDelegate(),
            delegateQueue: nil)
    }

    func imageData(for url: URL) async -> Data? {
        guard MetadataURLPolicy.allows(url) else { return nil }
        if let task = pending[url] { return await task.value }
        let cacheFile = cacheDirectory.appendingPathComponent(
            SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
        let session = self.session
        let task = Task<Data?, Never> {
            if let cached = try? Data(contentsOf: cacheFile),
               Self.validImage(cached) { return cached }
            do {
                var request = URLRequest(url: url)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                request.setValue("OpenPaste/1.0", forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      response.url.map(MetadataURLPolicy.allows) == true,
                      response.mimeType?.lowercased().hasPrefix("image/") == true,
                      response.expectedContentLength < 0 ||
                        response.expectedContentLength <= Int64(Self.maximumBytes) else { return nil }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < Self.maximumBytes else { return nil }
                    data.append(byte)
                }
                guard Self.validImage(data) else { return nil }
                try? FileManager.default.createDirectory(
                    at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheFile, options: .atomic)
                return data
            } catch { return nil }
        }
        pending[url] = task
        let result = await task.value
        pending[url] = nil
        return result
    }

    private static func validImage(_ data: Data) -> Bool {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
