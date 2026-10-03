import SwiftUI

struct DanmakuOverlay: View {
    let comments: [DanmakuComment]
    let currentTime: Double

    var body: some View {
        GeometryReader { geometry in
            let laneHeight: CGFloat = 30
            let laneCount = max(1, Int((geometry.size.height * 0.68) / laneHeight))
            ZStack {
                ForEach(activeComments.prefix(64)) { comment in
                    commentView(comment, size: geometry.size, laneCount: laneCount, laneHeight: laneHeight)
                }
            }
            .animation(.linear(duration: 0.5), value: currentTime)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var activeComments: [DanmakuComment] {
        comments.filter { comment in
            let lifetime = comment.position == .scrolling ? 8.0 : 4.0
            return currentTime >= comment.time && currentTime <= comment.time + lifetime
        }
    }

    @ViewBuilder
    private func commentView(_ comment: DanmakuComment, size: CGSize, laneCount: Int, laneHeight: CGFloat) -> some View {
        let lifetime = comment.position == .scrolling ? 8.0 : 4.0
        let progress = min(max((currentTime - comment.time) / lifetime, 0), 1)
        let lane = laneIndex(for: comment, laneCount: laneCount)
        let y: CGFloat = {
            switch comment.position {
            case .bottom: return max(laneHeight, size.height - laneHeight * CGFloat((lane % 3) + 1) - 52)
            case .top: return laneHeight * CGFloat((lane % 3) + 1)
            case .scrolling: return laneHeight * CGFloat(lane + 1)
            }
        }()
        let x: CGFloat = comment.position == .scrolling
            ? (size.width + 180) - CGFloat(progress) * (size.width + 360)
            : size.width / 2

        Text(comment.text)
            .font(.system(size: min(max(comment.fontSize, 12), 34), weight: .semibold))
            .foregroundStyle(color(comment.color))
            .lineLimit(1)
            .fixedSize()
            .shadow(color: .black, radius: 1.5, x: 1, y: 1)
            .position(x: x, y: y)
    }

    private func laneIndex(for comment: DanmakuComment, laneCount: Int) -> Int {
        let textSeed = comment.text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let timeSeed = Int(comment.time * 10)
        return abs(textSeed &+ timeSeed) % max(laneCount, 1)
    }

    private func color(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
