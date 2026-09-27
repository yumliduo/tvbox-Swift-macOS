import XCTest
@testable import TVBox

final class SourceSubtitleTests: XCTestCase {
    func testParsesSourceSubtitleListsAndPreservesNamesAndLanguages() {
        let result = SourceSubtitleParser.parse(from: ["subt": [
            ["name": "简体中文", "url": "https://example.com/zh.ass", "lang": "zh"],
            ["name": "English", "url": "https://example.com/en.srt", "lang": "en"]
        ]], mediaURL: URL(string: "https://example.com/video"), mediaHeaders: ["Cookie": "test=value"])
        XCTAssertEqual(result.map(\.title), ["简体中文", "English"])
        XCTAssertEqual(result.map(\.language), ["zh", "en"])
        XCTAssertEqual(result.first?.headers["Cookie"], "test=value")
    }

    func testAliasesJSONAndDuplicateEntriesAreHandledWithoutURLFragmentSplitting() {
        let result = SourceSubtitleParser.parse(from: [
            "subtitles": "[{\"label\":\"English\",\"src\":\"https://example.com/en.vtt#fragment\"}]",
            "subtitle": "https://example.com/en.vtt#fragment",
            "subs": ["title": "简体", "file": "https://example.com/zh.srt", "language": "zh-Hans"]
        ], mediaURL: nil, mediaHeaders: [:])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.url.fragment, "fragment")
        XCTAssertEqual(result.last?.language, "zh-Hans")
    }

    func testRejectsLocalCredentialsInvalidSchemesAndOversizedLists() {
        let invalid = ["file:///private/test.srt", "data:text/plain,test", "ftp://example.com/test.srt",
                       "https://user:secret@example.com/test.srt", "/relative.srt"]
        XCTAssertTrue(SourceSubtitleParser.parse(from: ["subt": invalid], mediaURL: nil, mediaHeaders: [:]).isEmpty)
        let many = (0..<100).map { "https://example.com/\($0).srt" }
        XCTAssertEqual(SourceSubtitleParser.parse(from: ["subt": many], mediaURL: nil, mediaHeaders: [:]).count, 64)
    }

    func testCredentialsOnlyInheritedOnSameOriginAndExplicitHeadersOverrideCaseInsensitively() {
        let result = SourceSubtitleParser.parse(from: ["subt": [
            ["url": "https://example.com/a.srt", "header": ["cookie": "override"]],
            ["url": "https://other.example/b.srt", "header": ["X-Token": "explicit"]],
            ["url": "http://example.com/c.srt"],
            ["url": "https://example.com:8443/d.srt"]
        ]], mediaURL: URL(string: "https://example.com/video"), mediaHeaders: ["Cookie": "private", "Authorization": "Bearer test"])
        XCTAssertEqual(result[0].headers, ["cookie": "override", "Authorization": "Bearer test"])
        XCTAssertEqual(result[1].headers, ["X-Token": "explicit"])
        XCTAssertTrue(result[2].headers.isEmpty)
        XCTAssertTrue(result[3].headers.isEmpty)
        XCTAssertEqual(SourceSubtitleParser.safeHeaders(["Bad\nName": "a", "Test": "a\0b", "Host": "test", "Good": "valid"]), ["Good": "valid"])
    }

    func testRedirectDropsCredentialsAcrossOriginsAndBlocksDowngrade() throws {
        var request = URLRequest(url: URL(string: "https://other.example/sub.srt")!)
        request.allHTTPHeaderFields = ["Authorization": "Bearer test", "Cookie": "test", "X-Private": "test"]
        let previous = URL(string: "https://example.com/sub.srt")!
        let redirected = try XCTUnwrap(SourceSubtitleLoader.redirect(request, from: previous))
        for header in ["Authorization", "Cookie", "X-Private"] {
            XCTAssertNil(redirected.value(forHTTPHeaderField: header))
        }
        request.url = URL(string: "https://example.com/next.srt")!
        XCTAssertEqual(SourceSubtitleLoader.redirect(request, from: previous)?.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        request.url = URL(string: "http://example.com/next.srt")!
        XCTAssertNil(SourceSubtitleLoader.redirect(request, from: previous))
        request.url = URL(string: "file:///private/test.srt")!
        XCTAssertNil(SourceSubtitleLoader.redirect(request, from: previous))
    }

    func testDownloaderPreservesSubtitleBytesAndRemovesPrivateTemporaryFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleURLProtocol.self]
        let loader = SourceSubtitleLoader(configuration: configuration)
        var file: SourceSubtitleFile? = try await loader.load(.init(title: "中文", url: URL(string: "https://example.com/valid.ass")!, headers: ["X-Test": "subtitle"]))
        let url = try XCTUnwrap(file?.url)
        XCTAssertEqual(try Data(contentsOf: url), SubtitleURLProtocol.body)
        XCTAssertEqual(url.pathExtension, "ass")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        file = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testDownloaderRejectsHTTPErrorEmptyAndOversizedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleURLProtocol.self]
        let loader = SourceSubtitleLoader(configuration: configuration)
        for path in ["error", "empty", "oversized", "stream-oversized"] {
            do {
                _ = try await loader.load(.init(title: "test", url: URL(string: "https://example.com/\(path)")!))
                XCTFail("Must reject \(path)")
            } catch { XCTAssertTrue(error is SourceSubtitleLoadError) }
        }
    }
}

private final class SubtitleURLProtocol: URLProtocol {
    static let body = Data("1\n00:00:00,000 --> 00:00:10,000\n测试字幕\n".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        var headers: [String: String] = [:]
        if path == "oversized" { headers["Content-Length"] = String(SourceSubtitleLoader.maximumBytes + 1) }
        if path == "valid.ass", request.value(forHTTPHeaderField: "X-Test") != "subtitle" {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "error" ? 403 : 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "stream-oversized" {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: SourceSubtitleLoader.maximumBytes + 1))
        } else if path != "empty" { client?.urlProtocol(self, didLoad: Self.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
