import Foundation

/// Normalizes source response fields and scopes subtitle request credentials.
enum SourceSubtitleParser {
    static func parse(from object: [String: Any], mediaURL: URL?, mediaHeaders: [String: String]) -> [SourceSubtitle] {
        var result: [SourceSubtitle] = []
        for key in ["subt", "subtitles", "subtitle", "subs"] {
            for entry in entries(object[key]) where result.count < 64 {
                let value = (entry as? [String: Any]) ?? (entry as? String).map { ["url": $0] } ?? [:]
                guard let address = (value["url"] ?? value["src"] ?? value["file"]) as? String,
                      let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                      isRemoteURL(url) else { continue }
                let title = cleanText((value["name"] ?? value["title"] ?? value["label"]) as? String)
                let language = cleanText((value["lang"] ?? value["language"]) as? String)
                // Media credentials belong to the media origin, not an arbitrary subtitle host.
                var headers = mediaURL.map { sameOrigin($0, url) } == true ? safeHeaders(mediaHeaders) : [:]
                for (name, headerValue) in safeHeaders(value["header"] ?? value["headers"]) {
                    headers = headers.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
                    headers[name] = headerValue
                }
                let subtitle = SourceSubtitle(title: title ?? "字幕 \(result.count + 1)", url: url,
                                              language: language, headers: headers)
                if !result.contains(where: { $0.url == url && $0.headers == headers }) { result.append(subtitle) }
            }
        }
        return result
    }

    static func isRemoteURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    static func safeHeaders(_ value: Any?) -> [String: String] {
        var value = value
        if let text = value as? String, let data = text.data(using: .utf8), data.count <= 262_144 {
            value = try? JSONSerialization.jsonObject(with: data)
        }
        guard let dictionary = value as? [String: String] else { return [:] }
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var result: [String: String] = [:]
        for name in dictionary.keys.sorted().prefix(32) {
            guard !name.isEmpty, name.count <= 64, name.unicodeScalars.allSatisfy(tokenCharacters.contains),
                  let content = dictionary[name], content.utf8.count <= 8192,
                  !content.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }),
                  !["host", "content-length", "connection", "transfer-encoding"].contains(name.lowercased()) else { continue }
            result[name] = content
        }
        return result
    }

    private static func entries(_ value: Any?) -> [Any] {
        if let values = value as? [Any] { return Array(values.prefix(64)) }
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
