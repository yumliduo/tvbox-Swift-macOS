import Foundation

/// Normalizes the standard TVBox playerContent `danmaku` field.
enum SourceDanmakuParser {
    static func parse(from object: [String: Any], mediaURL: URL?, mediaHeaders: [String: String]) -> [SourceDanmaku] {
        var result: [SourceDanmaku] = []
        for key in ["danmaku", "danmu"] {
            for entry in entries(object[key]) where result.count < 16 {
                let value = (entry as? [String: Any]) ?? (entry as? String).map { ["url": $0] } ?? [:]
                guard let address = (value["url"] ?? value["src"] ?? value["file"]) as? String,
                      let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                      SourceSubtitleParser.isRemoteURL(url) else { continue }
                let title = cleanText((value["name"] ?? value["title"] ?? value["label"]) as? String)
                var headers = mediaURL.map { SourceSubtitleParser.sameOrigin($0, url) } == true
                    ? SourceSubtitleParser.safeHeaders(mediaHeaders) : [:]
                for (name, headerValue) in SourceSubtitleParser.safeHeaders(value["header"] ?? value["headers"]) {
                    headers = headers.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
                    headers[name] = headerValue
                }
                let source = SourceDanmaku(title: title ?? "弹幕 (result.count + 1)", url: url, headers: headers)
                if !result.contains(where: { $0.url == url && $0.headers == headers }) { result.append(source) }
            }
        }
        return result
    }

    private static func entries(_ value: Any?) -> [Any] {
        if let values = value as? [Any] { return Array(values.prefix(16)) }
        if let value = value as? [String: Any] { return [value] }
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 524_288 else { return [] }
        if let data = value.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data),
           decoded is [Any] || decoded is [String: Any] { return entries(decoded) }
        return [value]
    }

    private static func cleanText(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(160))
    }
}
