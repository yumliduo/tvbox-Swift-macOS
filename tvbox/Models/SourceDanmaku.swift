import Foundation

/// A remote danmaku document advertised by a source's player response.
struct SourceDanmaku: Equatable, Sendable {
    let title: String
    let url: URL
    var headers: [String: String] = [:]
}

/// A single normalized comment rendered over the video timeline.
struct DanmakuComment: Identifiable, Equatable, Sendable {
    enum Position: Equatable, Sendable {
        case scrolling
        case top
        case bottom
    }

    let id: UUID
    let time: Double
    let text: String
    let position: Position
    let color: UInt32
    let fontSize: Double

    init(
        id: UUID = UUID(),
        time: Double,
        text: String,
        position: Position = .scrolling,
        color: UInt32 = 0xFFFFFF,
        fontSize: Double = 25
    ) {
        self.id = id
        self.time = time
        self.text = text
        self.position = position
        self.color = color
        self.fontSize = fontSize
    }
}
