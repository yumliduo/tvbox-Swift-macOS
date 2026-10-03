import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum SourceDanmakuLoadError: Error {
    case invalidURL
    case invalidResponse
    case tooLarge
    case unsupportedFormat
}

final class SourceDanmakuLoader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumComments = 20_000
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
    }

    func load(_ source: SourceDanmaku) async throws -> [DanmakuComment] {
        guard SourceSubtitleParser.isRemoteURL(source.url) else { throw SourceDanmakuLoadError.invalidURL }
        let configuration = self.configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source.url)
        request.allHTTPHeaderFields = SourceSubtitleParser.safeHeaders(source.headers)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw SourceDanmakuLoadError.invalidResponse
        }
        guard response.expectedContentLength <= Self.maximumBytes else { throw SourceDanmakuLoadError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw SourceDanmakuLoadError.tooLarge }
            data.append(byte)
        }
        return try Self.parse(data: data)
    }

    static func parse(data: Data) throws -> [DanmakuComment] {
        let prefix = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let comments: [DanmakuComment]
        if prefix.hasPrefix("<") {
            let delegate = BilibiliDanmakuXMLDelegate(limit: maximumComments)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            guard parser.parse() else { throw SourceDanmakuLoadError.unsupportedFormat }
            comments = delegate.comments
        } else {
            comments = try parseJSON(data)
        }
        return comments.sorted { lhs, rhs in
            lhs.time == rhs.time ? lhs.text < rhs.text : lhs.time < rhs.time
        }
    }

    private static func parseJSON(_ data: Data) throws -> [DanmakuComment] {
        let value = try JSONSerialization.jsonObject(with: data)
        let entries: [Any]
        if let array = value as? [Any] {
            entries = array
        } else if let object = value as? [String: Any] {
            entries = (object["danmaku"] ?? object["comments"] ?? object["data"] ?? []) as? [Any] ?? []
        } else {
            throw SourceDanmakuLoadError.unsupportedFormat
        }
        return entries.prefix(maximumComments).compactMap(parseJSONEntry)
    }

    private static func parseJSONEntry(_ value: Any) -> DanmakuComment? {
        if let array = value as? [Any], array.count >= 4 {
            guard let time = number(array[0]), let text = cleanText(array[3] as? String) else { return nil }
            return DanmakuComment(time: max(0, time), text: text,
                                  position: position(number(array[1])), color: color(array[2]), fontSize: 25)
        }
        guard let object = value as? [String: Any],
              let text = cleanText((object["text"] ?? object["content"] ?? object["m"]) as? String) else { return nil }
        var time = number(object["time"] ?? object["t"] ?? object["progress"]) ?? 0
        if object["progress"] != nil && time > 1_000 { time /= 1_000 }
        return DanmakuComment(time: max(0, time), text: text,
                              position: position(number(object["mode"] ?? object["type"])),
                              color: color(object["color"]),
                              fontSize: min(max(number(object["size"] ?? object["fontSize"]) ?? 25, 12), 42))
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func position(_ value: Double?) -> DanmakuComment.Position {
        switch Int(value ?? 1) {
        case 4: return .bottom
        case 5: return .top
        default: return .scrolling
        }
    }

    private static func color(_ value: Any?) -> UInt32 {
        if let value = value as? NSNumber { return UInt32(clamping: value.int64Value) & 0xFFFFFF }
        guard var text = value as? String else { return 0xFFFFFF }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isHex = text.hasPrefix("#") || text.hasPrefix("0x")
        if text.hasPrefix("#") { text.removeFirst() }
        if text.hasPrefix("0x") { text.removeFirst(2) }
        return UInt32(text, radix: isHex ? 16 : 10) ?? 0xFFFFFF
    }

    fileprivate static func cleanText(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0.value == 9
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(300))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(SourceSubtitleLoader.redirect(request, from: response.url))
    }
}

private final class BilibiliDanmakuXMLDelegate: NSObject, XMLParserDelegate {
    let limit: Int
    var comments: [DanmakuComment] = []
    private var attributes: [String: String]?
    private var text = ""

    init(limit: Int) { self.limit = limit }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "d", comments.count < limit else { return }
        attributes = attributeDict
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard attributes != nil, text.count < 600 else { return }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "d", let attributes else { return }
        defer { self.attributes = nil; text = "" }
        let fields = (attributes["p"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        guard let time = fields.first.flatMap({ Double($0) }),
              let content = SourceDanmakuLoader.cleanText(text) else { return }
        let mode = fields.count > 1 ? Double(fields[1]) : nil
        let size = fields.count > 2 ? Double(fields[2]) ?? 25 : 25
        let color = fields.count > 3 ? UInt32(fields[3]) ?? 0xFFFFFF : 0xFFFFFF
        let position: DanmakuComment.Position
        switch Int(mode ?? 1) {
        case 4: position = .bottom
        case 5: position = .top
        default: position = .scrolling
        }
        comments.append(DanmakuComment(time: max(0, time), text: content, position: position,
                                       color: color & 0xFFFFFF, fontSize: min(max(size, 12), 42)))
    }
}
