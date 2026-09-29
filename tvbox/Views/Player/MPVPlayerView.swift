import SwiftUI

#if os(macOS) && canImport(Libmpv)
import AppKit
import QuartzCore

/// Ignore MoltenVK's teardown-only 1×1 resize, which otherwise leaves a black
/// surface when the same playback session moves between inline and fullscreen.
final class MPVMetalLayer: CAMetalLayer {
    // ObjC dispatch is required for the backend KVO observer, including paused resize.
    @objc dynamic override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue } }
    }
}

final class MPVVideoCanvas: NSView {
    let metalLayer = MPVMetalLayer()
    var onKeyboardAction: ((MPVKeyboardAction) -> Void)?
    private var keyboardMonitor: Any?

    deinit {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.framebufferOnly = true
        layer = metalLayer
        wantsLayer = true
        resizeSurface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    func focusForPlayback() { window?.makeFirstResponder(self) }
    override func layout() { super.layout(); resizeSurface() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resizeSurface() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeSurface()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        guard window != nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKeyboardEvent(event) else { return event }
            return nil
        }
    }

    /// Scoped to the visible playback surface, including when it is reparented
    /// for fullscreen. Never steals first responder from text fields or controls.
    func handleKeyboardEvent(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, event.window === window,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty,
              !(window.firstResponder is NSTextView),
              !(window.firstResponder is NSControl),
              let action = MPVKeyboardAction(event: event),
              let onKeyboardAction else { return false }
        // Holding Space must not alternate pause/play on every key repeat.
        if action != .togglePause || !event.isARepeat { onKeyboardAction(action) }
        return true
    }
    private func resizeSurface() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: max(2, bounds.width * scale), height: max(2, bounds.height * scale))
        CATransaction.commit()
    }
}

private struct MPVSurface: NSViewRepresentable {
    @ObservedObject var controller: MPVPlayerController
    var onKeyboardAction: (MPVKeyboardAction) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        let canvas = controller.canvas
        canvas.onKeyboardAction = onKeyboardAction
        if canvas.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            canvas.removeFromSuperview()
            canvas.frame = container.bounds
            canvas.autoresizingMask = [.width, .height]
            container.addSubview(canvas)
        }
    }
    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Only detach views still owned by this container; fullscreen may have
        // already reparented the canvas into its new container.
        container.subviews.forEach {
            ($0 as? MPVVideoCanvas)?.onKeyboardAction = nil
            $0.removeFromSuperview()
        }
    }
}

struct MPVPlayerView: View {
    let urlString: String
    var headers: [String: String] = [:]
    var sourceSubtitles: [SourceSubtitle] = []
    var startPosition: Double = 0
    var isLive = false
    var onProgressChanged: ((Double, Double?) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onPlaybackFailed: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var canPlayNext = false
    var onPlayNext: (() -> Void)?
    var sharedController: MPVPlayerController?
    @StateObject private var ownedController = MPVPlayerController()
    @AppStorage(HawkConfig.PLAY_DECODE_MODE) private var decodeRaw = 0
    @State private var sleepOwner = UUID()
    private var controller: MPVPlayerController { sharedController ?? ownedController }

    var body: some View {
        MPVPlayerContent(controller: controller, isLive: isLive, onToggleFullScreen: onToggleFullScreen,
                         canPlayNext: canPlayNext, onPlayNext: onPlayNext, retry: { start() })
            .onAppear { start() }
            .onChange(of: urlString) { _, _ in start() }
            .onChange(of: headers) { _, _ in start() }
            .onChange(of: sourceSubtitles) { _, _ in start() }
            .onChange(of: decodeRaw) { _, _ in start(position: controller.currentTimeSeconds) }
            .onReceive(controller.$isPlaying) { playing in
                PlaybackSleepPreventer.shared.setPlaybackActive(playing, owner: sleepOwner)
            }
            .onDisappear {
                PlaybackSleepPreventer.shared.end(owner: sleepOwner)
                if sharedController == nil { controller.stop() }
            }
    }

    private func start(position: Double? = nil) {
        guard let url = URL(string: urlString), url.scheme != nil else { return }
        controller.play(url: url, headers: headers, sourceSubtitles: sourceSubtitles, startPosition: position ?? startPosition, isLive: isLive,
                        onProgressChanged: onProgressChanged, onPlaybackEnded: onPlaybackEnded,
                        onPlaybackFailed: onPlaybackFailed)
    }
}

private struct MPVPlayerContent: View {
    @ObservedObject var controller: MPVPlayerController
    var isLive: Bool
    var onToggleFullScreen: (() -> Void)?
    var canPlayNext: Bool
    var onPlayNext: (() -> Void)?
    var retry: () -> Void
    @State private var showControls = true
    @State private var interaction = UUID()
    @State private var dragging = false
    @State private var seekPosition: Double = 0
    @AppStorage(HawkConfig.PLAY_TIME_STEP) private var seekStep = 10

    var body: some View {
        ZStack {
            Color.black
            MPVSurface(controller: controller, onKeyboardAction: handleKeyboardAction)
            if controller.isPreparing { ProgressView().tint(.white).allowsHitTesting(false) }
            if let message = controller.errorMessage {
                VStack(spacing: 12) {
                    Text(message).multilineTextAlignment(.center)
                    Button("重试") { controller.stop(); retry() }
                }.padding().background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            }
            if showControls {
                VStack {
                    HStack {
                        Text("mpv · \(controller.decodeDescription)").font(.caption)
                        Spacer()
                    }
                    Spacer()
                    VStack(spacing: 12) {
                        if !isLive, controller.durationSeconds > 0 {
                            HStack {
                                Text(time(dragging ? seekPosition : controller.currentTimeSeconds))
                                Slider(value: Binding(get: { dragging ? seekPosition : controller.currentTimeSeconds },
                                                      set: { seekPosition = $0 }),
                                       in: 0...max(1, controller.durationSeconds), onEditingChanged: { editing in
                                    dragging = editing
                                    wakeControls()
                                    if !editing { controller.seek(to: seekPosition) }
                                }).accessibilityLabel("播放进度")
                                Text(time(controller.durationSeconds))
                            }.font(.caption.monospacedDigit())
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 20) {
                                playbackOptions.frame(maxWidth: .infinity, alignment: .leading)
                                transportControls
                                volumeControls.frame(maxWidth: .infinity, alignment: .trailing)
                            }.frame(minWidth: 760)
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    transportControls
                                    Spacer(minLength: 8)
                                    volumeControls
                                }
                                ScrollView(.horizontal, showsIndicators: false) { playbackOptions }
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                    }.padding(16).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                }.padding(16)
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { controller.canvas.focusForPlayback(); wakeControls() }
        .onContinuousHover { phase in if case .active = phase { wakeControls() } }
        .task(id: interaction) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !dragging else { return }
            showControls = false
        }
    }
    private var playbackOptions: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button("\(rate.formatted())×") { controller.setRate(rate) }
                }
            } label: { Text("\(controller.playbackRate.formatted())×") }
            SubtitleMenu(state: controller.subtitles, onSelect: controller.selectSubtitle)
            Menu {
                Text("正数延后，负数提前；仅影响独立字幕轨")
                Button("提前 0.5 秒") { controller.setSubtitleDelay(controller.subtitleDelay - 0.5) }
                Button("延后 0.5 秒") { controller.setSubtitleDelay(controller.subtitleDelay + 0.5) }
                Button("重置为 0 秒") { controller.setSubtitleDelay(0) }
            } label: { Text("字幕偏移 \(controller.subtitleDelay.formatted())s") }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var transportControls: some View {
        HStack(spacing: 16) {
            if !isLive {
                Button { handleKeyboardAction(.seekBackward) } label: {
                    Image(systemName: "gobackward")
                }.accessibilityLabel("快退").help("快退 \(max(1, seekStep)) 秒（←）")
            }
            Button { handleKeyboardAction(.togglePause) } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18)).frame(width: 28, height: 28)
            }.accessibilityLabel(controller.isPlaying ? "暂停" : "播放").help("播放 / 暂停（空格）")
            if !isLive {
                Button { handleKeyboardAction(.seekForward) } label: {
                    Image(systemName: "goforward")
                }.accessibilityLabel("快进").help("快进 \(max(1, seekStep)) 秒（→）")
            }
            if canPlayNext {
                Button { onPlayNext?() } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("下一集")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var volumeControls: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            Slider(value: Binding(get: { controller.volume }, set: controller.setVolume), in: 0...200)
                .frame(width: 90).accessibilityLabel("音量").help("音量（↑ / ↓，每次 5%）")
            Text("\(Int(controller.volume))%")
                .monospacedDigit().frame(width: 38, alignment: .trailing)
            if let onToggleFullScreen {
                Button(action: onToggleFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("切换全屏").help("切换全屏")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func handleKeyboardAction(_ action: MPVKeyboardAction) {
        switch action {
        case .togglePause: controller.togglePause()
        case .seekBackward:
            if !isLive { controller.seek(to: controller.currentTimeSeconds - Double(max(1, seekStep))) }
        case .seekForward:
            if !isLive { controller.seek(to: controller.currentTimeSeconds + Double(max(1, seekStep))) }
        case .volumeDown: controller.setVolume(controller.volume - 5)
        case .volumeUp: controller.setVolume(controller.volume + 5)
        }
        wakeControls()
    }

    private func wakeControls() { showControls = true; interaction = UUID() }
    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
#else
struct MPVPlayerView: View {
    let urlString: String
    var body: some View { Text("当前平台暂不支持 mpv") }
}
#endif
