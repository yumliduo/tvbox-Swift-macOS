import Foundation

/// Ownership follows the mpv session, so a file outlives native subtitle parsing.
final class SourceSubtitleFile: @unchecked Sendable {
    let url: URL
    private let directory: URL

    init(data: Data, fileExtension: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tvbox-sub-" + UUID().uuidString, isDirectory: true)
        let ext = ["srt", "ass", "ssa", "vtt", "sub", "ttml"].contains(fileExtension.lowercased()) ? fileExtension.lowercased() : "srt"
        url = directory.appendingPathComponent("subtitle." + ext)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum SourceSubtitleLoadError: Error { case invalidURL, invalidResponse, tooLarge, empty }

final class SourceSubtitleLoader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
    }

    func load(_ subtitle: SourceSubtitle) async throws -> SourceSubtitleFile {
        guard SourceSubtitleParser.isRemoteURL(subtitle.url) else { throw SourceSubtitleLoadError.invalidURL }
        let configuration = self.configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: subtitle.url)
        request.allHTTPHeaderFields = SourceSubtitleParser.safeHeaders(subtitle.headers)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw SourceSubtitleLoadError.invalidResponse
        }
        guard response.expectedContentLength <= Self.maximumBytes else { throw SourceSubtitleLoadError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw SourceSubtitleLoadError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw SourceSubtitleLoadError.empty }
        return try SourceSubtitleFile(data: data, fileExtension: subtitle.url.pathExtension)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirect(request, from: response.url))
    }

    static func redirect(_ request: URLRequest, from previousURL: URL?) -> URLRequest? {
        guard let destination = request.url, SourceSubtitleParser.isRemoteURL(destination), let previousURL,
              !(previousURL.scheme?.lowercased() == "https" && destination.scheme?.lowercased() == "http") else { return nil }
        if !SourceSubtitleParser.sameOrigin(previousURL, destination) {
            // URLSession may copy arbitrary source headers to a redirect. Drop all
            // of them at the origin boundary, including cookies and signed tokens.
            return URLRequest(url: destination, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
        }
        return request
    }
}
