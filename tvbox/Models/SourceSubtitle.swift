import Foundation

/// An external subtitle advertised by a source's player response. Never persisted.
struct SourceSubtitle: Equatable, Sendable {
    let title: String
    let url: URL
    var language: String? = nil
    var headers: [String: String] = [:]
}
