import XCTest
@testable import TVBox
#if os(macOS) && canImport(Libmpv)
import AppKit
import SwiftUI
import CoreAudio
#endif

@MainActor
final class MPVPlayerTests: XCTestCase {
    func testEnginePreservesOldStoredValuesAndOnlyOffersLinkedMPV() {
        XCTAssertEqual(PlayerEngine.fromStoredValue(0), .system)
        XCTAssertEqual(PlayerEngine.fromStoredValue(10), PlayerEngine.isVLCAvailable ? .vlc : .system)
        XCTAssertEqual(PlayerEngine.fromStoredValue(20), PlayerEngine.isMPVAvailable ? .mpv : .system)
        XCTAssertEqual(PlayerEngine.availableEngines.contains(.mpv), PlayerEngine.isMPVAvailable)
        XCTAssertEqual(PlayerEngine.fromStoredValue(999), .system)
    }

    func testHardwareModesExplicitlyRequestVideoToolboxAndSoftwareDisablesIt() {
        XCTAssertEqual(VideoDecodeMode.auto.mpvHardwareDecodeOption, "videotoolbox")
        XCTAssertEqual(VideoDecodeMode.hardware.mpvHardwareDecodeOption, "videotoolbox")
        XCTAssertEqual(VideoDecodeMode.software.mpvHardwareDecodeOption, "no")
    }

    func testHeadersPreserveTokensButRejectLineAndNullInjection() {
        XCTAssertEqual(MPVPlaybackOptions.headerFields([
            "Cookie": "one=a,b; two=c\\d", "Referer": "https://example.com/",
            "Bad\r\nHeader": "injection", "X-Test": "bad\nvalue", "Null": "a\0b"
        ]), ["Cookie: one=a,b; two=c\\d", "Referer: https://example.com/"])
        XCTAssertEqual(MPVPlaybackOptions.rate(.nan), 1)
        XCTAssertEqual(MPVPlaybackOptions.rate(0), 1)
        XCTAssertEqual(MPVPlaybackOptions.rate(1.5), 1.5)
    }

    func testSessionIdentityIncludesHeadersDecodeModeAndLiveMode() {
        let one = MPVPlaybackOptions.Identity(url: URL(string: "https://example.com/movie.mp4")!, headers: [:], isLive: false, decode: .hardware)
        var changed = one
        changed.headers = ["Referer": "https://example.com/"]
        XCTAssertNotEqual(one, changed)
        changed = one; changed.decode = .software
        XCTAssertNotEqual(one, changed)
        changed = one; changed.isLive = true
        XCTAssertNotEqual(one, changed)
    }

    #if os(macOS) && canImport(Libmpv)
    func testAudioDeviceNotificationAfterPlayerTeardown() async throws {
        // Mono initialization fails in CoreAudio on the affected macOS version.
        // Before the backport, the next device notification crashes in hotplug_cb.
        let url = try makeSilentAudio(channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<10 {
            let controller = MPVPlayerController()
            controller.play(url: url, decodeMode: .hardware)
            defer { controller.stop() }
            try await waitUntil(controller) { controller.durationSeconds > 0 }
            try await Task.sleep(nanoseconds: 500_000_000)
            controller.stop()
            try await Task.sleep(nanoseconds: 400_000_000)
            try await triggerAudioDeviceChange()
            XCTAssertFalse(controller.isPlaying)
            XCTAssertEqual(controller.currentTimeSeconds, 0)
        }
    }

    func testStereoPlaybackSurvivesHotplugIdlePauseAndRepeatedTeardown() async throws {
        let url = try makeSilentAudio(channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        for iteration in 0..<5 {
            let controller = MPVPlayerController()
            controller.play(url: url, decodeMode: .hardware)
            defer { controller.stop() }
            try await waitUntil(controller) { controller.currentTimeSeconds > 0.3 && controller.isPlaying }
            try await triggerAudioDeviceChange()
            controller.pause(true)
            try await waitUntil(controller) { !controller.isPlaying }
            // CoreAudio schedules an idle shutdown after seven seconds.
            if iteration == 0 { try await Task.sleep(nanoseconds: 8_000_000_000) }
            controller.pause(false)
            try await waitUntil(controller) { controller.isPlaying }
            controller.stop()
            try await Task.sleep(nanoseconds: 400_000_000)
            try await triggerAudioDeviceChange()
            XCTAssertFalse(controller.isPlaying)
        }
    }

    private func makeSilentAudio(channels: UInt16) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let frameBytes = channels * 2
        let samples = Data(count: 48_000 * Int(frameBytes) * 30)
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples.count))
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(UInt32(48_000))
        append(UInt32(48_000) * UInt32(frameBytes))
        append(frameBytes)
        append(UInt16(16))
        wav.append(Data("data".utf8))
        append(UInt32(samples.count))
        wav.append(samples)
        try wav.write(to: url)
        return url
    }

    private func triggerAudioDeviceChange() async throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let notification = expectation(description: "CoreAudio delivered device change")
        notification.assertForOverFulfill = false
        let listener: AudioObjectPropertyListenerBlock = { _, _ in notification.fulfill() }
        let system = AudioObjectID(kAudioObjectSystemObject)
        XCTAssertEqual(AudioObjectAddPropertyListenerBlock(system, &address, .main, listener), noErr)
        defer { AudioObjectRemovePropertyListenerBlock(system, &address, .main, listener) }
        // Private and empty: never changes the user's default output or volume.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TVBox regression probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true
        ]
        var device = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        XCTAssertEqual(status, noErr)
        guard status == noErr else { throw MPVTestError.failed }
        defer { XCTAssertEqual(AudioHardwareDestroyAggregateDevice(device), noErr) }
        await fulfillment(of: [notification], timeout: 2)
    }

    func testRealMPVHardwarePlaybackSubtitleSelectionSeekAndSessionReuse() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        let controller = MPVPlayerController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        var progress: Double = 0
        controller.play(url: url, decodeMode: .hardware, onProgressChanged: { time, _ in progress = time })
        window.contentView = controller.canvas
        window.orderFront(nil)
        defer { controller.stop(); window.orderOut(nil); window.contentView = nil }
        try await waitUntil(controller) { controller.currentTimeSeconds > 0.5 && controller.subtitles.tracks.count == 2 }
        XCTAssertTrue(controller.isActuallyPlaying)
        XCTAssertEqual(controller.decoder, "videotoolbox", "Requested hardware decoding must actually be active")
        XCTAssertGreaterThan(progress, 0)
        let chinese = try XCTUnwrap(controller.subtitles.tracks.first { $0.language?.hasPrefix("zh") == true || $0.language == "chi" })
        try await waitUntil(controller) { controller.subtitles.selectedTrackID == chinese.id }
        let english = try XCTUnwrap(controller.subtitles.tracks.first { $0.id != chinese.id })
        controller.selectSubtitle(.track(english.id))
        try await waitUntil(controller) { controller.subtitles.selectedTrackID == english.id }
        controller.setSubtitleDelay(-2)
        XCTAssertEqual(controller.subtitleDelay, -2)
        let identity = controller.renderID
        controller.play(url: url, decodeMode: .hardware)
        XCTAssertEqual(controller.renderID, identity, "Fullscreen reattachment must not reload media")
        XCTAssertEqual(controller.subtitles.selection, .track(english.id))
        XCTAssertEqual(controller.subtitleDelay, -2)
        controller.pause(true)
        try await waitUntil(controller) { !controller.isPlaying }
        controller.seek(to: 5)
        try await waitUntil(controller) { abs(controller.currentTimeSeconds - 5) < 0.5 }
        controller.selectSubtitle(.off)
        try await waitUntil(controller) { controller.subtitles.selectedTrackID == nil }
        controller.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(controller.currentTimeSeconds, 0, "Late session callbacks must not restore stopped playback")
        XCTAssertFalse(controller.isPlaying)
        XCTAssertTrue(controller.subtitles.tracks.isEmpty)
    }

    func testRealMPVSoftwareModeAndEndCallback() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        let controller = MPVPlayerController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        var ended = 0
        controller.play(url: url, startPosition: 9, decodeMode: .software, onPlaybackEnded: { ended += 1 })
        window.contentView = controller.canvas
        window.orderFront(nil)
        defer { controller.stop(); window.orderOut(nil); window.contentView = nil }
        try await waitUntil(controller) { controller.currentTimeSeconds >= 9 }
        XCTAssertEqual(controller.decoder, "no")
        try await waitUntil(controller) { ended == 1 }
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.isPreparing)
    }

    func testSourceSubtitlesLoadSwitchCloseAndSurviveFullscreenWithoutDuplicates() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        let sources = [SourceSubtitle(title: "简体来源", url: URL(string: "https://example.com/zh.srt")!, language: "zh"),
                       SourceSubtitle(title: "English source", url: URL(string: "https://example.com/en.srt")!, language: "en")]
        var requests: [URL] = []
        var files: [URL] = []
        let controller = MPVPlayerController { subtitle in
            requests.append(subtitle.url)
            let file = try SourceSubtitleFile(data: Data("1\n00:00:00,000 --> 00:00:12,000\n\(subtitle.title)\n".utf8), fileExtension: "srt")
            files.append(file.url)
            return file
        }
        controller.play(url: url, sourceSubtitles: sources, decodeMode: .hardware)
        defer { controller.stop() }
        try await waitUntil(controller) { controller.durationSeconds > 0 && controller.subtitles.tracks.count == 4 }
        controller.pause(true)
        controller.selectSubtitle(.track(-1))
        try await waitUntil(controller) { controller.subtitles.selectedTrackID == -1 }
        XCTAssertEqual(controller.decoder, "videotoolbox")
        controller.setSubtitleDelay(-2)
        controller.selectSubtitle(.track(-2))
        try await waitUntil(controller) { controller.subtitles.selectedTrackID == -2 }
        XCTAssertEqual(controller.subtitles.tracks.count, 4, "Loaded external tracks must not be listed twice")
        XCTAssertEqual(requests, sources.map(\.url))
        controller.selectSubtitle(.track(-1))
        try await waitUntil(controller) { controller.subtitles.selectedTrackID == -1 }
        XCTAssertEqual(requests.count, 2, "Switching back should reuse the loaded subtitle")
        let renderID = controller.renderID
        controller.play(url: url, sourceSubtitles: sources, decodeMode: .hardware)
        XCTAssertEqual(controller.renderID, renderID)
        XCTAssertEqual(controller.subtitleDelay, -2)
        controller.selectSubtitle(.off)
        try await waitUntil(controller) { controller.subtitles.selectedTrackID == nil }
        controller.stop()
        for _ in 0..<100 {
            if files.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(controller.subtitles.tracks.isEmpty)
    }

    func testSourceSubtitleFailureIsNonfatalAndLateDownloadCannotUndoOffOrEpisodeChange() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        let sources = [SourceSubtitle(title: "slow", url: URL(string: "https://example.com/slow.srt")!),
                       SourceSubtitle(title: "broken", url: URL(string: "https://example.com/broken.srt")!),
                       SourceSubtitle(title: "invalid format", url: URL(string: "https://example.com/invalid.srt")!)]
        var completed = 0
        var failedDownloads = 0
        var failures = 0
        let controller = MPVPlayerController { subtitle in
            if subtitle.title == "broken" {
                failedDownloads += 1
                if failedDownloads == 1 { throw SourceSubtitleLoadError.invalidResponse }
            }
            if subtitle.title == "slow" { try? await Task.sleep(nanoseconds: 600_000_000) }
            completed += 1
            let text = subtitle.title == "invalid format" ? "not a subtitle" : "1\n00:00:00,000 --> 00:00:12,000\nExternal\n"
            return try SourceSubtitleFile(data: Data(text.utf8), fileExtension: "srt")
        }
        controller.play(url: url, sourceSubtitles: sources, decodeMode: .hardware, onPlaybackFailed: { failures += 1 })
        defer { controller.stop() }
        try await waitUntil(controller) { controller.durationSeconds > 0 }
        controller.pause(true)
        controller.selectSubtitle(.track(-2))
        try await waitUntil(controller) { controller.subtitles.statusMessage?.contains("失败") == true }
        XCTAssertNil(controller.errorMessage)
        controller.selectSubtitle(.track(-2))
        try await waitUntil(controller) { controller.subtitles.selectedTrackID == -2 }
        XCTAssertEqual(failedDownloads, 2)
        XCTAssertNil(controller.subtitles.statusMessage)
        controller.selectSubtitle(.track(-3))
        try await waitUntil(controller) { controller.subtitles.statusMessage?.contains("失败") == true }
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(failures, 0)
        controller.selectSubtitle(.track(-1))
        await Task.yield()
        controller.selectSubtitle(.off)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertGreaterThan(completed, 0)
        XCTAssertNil(controller.subtitles.selectedTrackID)
        XCTAssertNil(controller.subtitles.statusMessage)
        XCTAssertEqual(controller.subtitles.selection, .off)
        controller.selectSubtitle(.track(-1))
        await Task.yield()
        controller.play(url: url, decodeMode: .hardware)
        try await waitUntil(controller) { controller.durationSeconds > 0 }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(controller.subtitles.tracks.allSatisfy { $0.id >= 0 })
        XCTAssertNil(controller.subtitles.statusMessage)
        XCTAssertNil(controller.errorMessage)
    }

    func testFullscreenReparentAndWindowResizeKeepMetalSurfaceAtCanvasSize() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        let controller = MPVPlayerController()
        let presentation = ResizePresentation()
        let host = NSHostingView(rootView: ResizeHarness(url: url, controller: controller, presentation: presentation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { controller.stop(); window.orderOut(nil); window.contentView = nil }
        try await waitUntil(controller) { controller.durationSeconds > 0 && controller.canvas.window != nil && controller.subtitles.tracks.count == 2 }
        let identity = controller.renderID
        let english = try XCTUnwrap(controller.subtitles.tracks.first { $0.language == "eng" })
        controller.selectSubtitle(.track(english.id))
        controller.setSubtitleDelay(-1.5)
        for paused in [false, true] {
            controller.pause(paused)
            try await waitUntil(controller) { controller.isPlaying != paused }
            for fullScreen in [true, false, true] {
                presentation.fullScreen = fullScreen
                for size in [CGSize(width: 1200, height: 800), CGSize(width: 1000, height: 700)] {
                    window.setContentSize(size)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 350_000_000)
                    let canvas = controller.canvas
                    let expected = fullScreen ? host.bounds.size : CGSize(width: 640, height: 360)
                    XCTAssertEqual(canvas.bounds.width, expected.width, accuracy: 1, "Canvas must fill fullscreen host")
                    XCTAssertEqual(canvas.bounds.height, expected.height, accuracy: 1, "Canvas must fill fullscreen host")
                    XCTAssertEqual(canvas.metalLayer.frame, canvas.bounds, "Metal frame must follow canvas after fullscreen/resize")
                    let scale = window.backingScaleFactor
                    XCTAssertEqual(canvas.metalLayer.drawableSize.width, canvas.bounds.width * scale, accuracy: 1,
                                   "Render width must follow the fullscreen pixel width")
                    XCTAssertEqual(canvas.metalLayer.drawableSize.height, canvas.bounds.height * scale, accuracy: 1,
                                   "Render height must follow the fullscreen pixel height")
                    let renderedSize = await controller.outputSizeForTesting()
                    XCTAssertEqual(renderedSize.width, canvas.bounds.width * scale, accuracy: 1,
                                   "mpv must render across the fullscreen width")
                    XCTAssertEqual(renderedSize.height, canvas.bounds.height * scale, accuracy: 1,
                                   "mpv must render across the fullscreen height")
                    XCTAssertEqual(controller.renderID, identity)
                    XCTAssertEqual(controller.subtitles.selectedTrackID, english.id)
                    XCTAssertEqual(controller.subtitleDelay, -1.5)
                    XCTAssertEqual(controller.decoder, "videotoolbox")
                }
            }
        }
    }

    func testMetalDrawableSizeChangesNotifyNativeObservers() {
        let layer = MPVMetalLayer()
        var changes = 0
        let observation = layer.observe(\.drawableSize) { _, _ in changes += 1 }
        layer.drawableSize = CGSize(width: 1280, height: 720)
        withExtendedLifetime(observation) {
            XCTAssertEqual(changes, 1, "Native resize observer must wake a paused VO")
        }
    }

    func testMetalResizeNotificationsAreSafeDuringAndAfterSessionTeardown() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        for _ in 0..<8 {
            let controller = MPVPlayerController()
            controller.play(url: url, decodeMode: .hardware)
            let canvas = controller.canvas
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFront(nil)
            defer { controller.stop(); window.orderOut(nil); window.contentView = nil }
            try await waitUntil(controller) { controller.durationSeconds > 0 }
            controller.pause(true)
            canvas.metalLayer.drawableSize = CGSize(width: 1600, height: 900)
            controller.stop()
            // Keep the old layer alive while the native queue unregisters KVO,
            // and after it has destroyed the VO. Late notifications must be inert.
            for step in 0..<20 {
                canvas.metalLayer.drawableSize = CGSize(width: 1280 + step * 2, height: 720 + step * 2)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(controller.currentTimeSeconds, 0)
            XCTAssertNil(controller.errorMessage)
        }
    }

    func testKeyboardActionsIgnoreModifiedAndUnrelatedKeys() throws {
        let mappings: [(UInt16, MPVKeyboardAction)] = [
            (49, .togglePause), (123, .seekBackward), (124, .seekForward),
            (125, .volumeDown), (126, .volumeUp)
        ]
        for (key, action) in mappings {
            XCTAssertEqual(MPVKeyboardAction(event: keyEvent(key)), action)
            for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
                XCTAssertNil(MPVKeyboardAction(event: keyEvent(key, modifiers: modifier)))
            }
        }
        XCTAssertNil(MPVKeyboardAction(event: keyEvent(0)))
    }

    func testKeyboardRoutingRespectsWindowFocusEditingVisibilityAndTeardown() async throws {
        let canvas = MPVVideoCanvas(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = KeyboardTestWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: canvas.frame)
        container.addSubview(canvas)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        var actions: [MPVKeyboardAction] = []
        canvas.onKeyboardAction = { actions.append($0) }
        NSApp.sendEvent(keyEvent(49, window: window))
        NSApp.sendEvent(keyEvent(49, window: window, repeated: true))
        XCTAssertEqual(actions, [.togglePause], "Holding Space must not toggle repeatedly")
        XCTAssertFalse(canvas.handleKeyboardEvent(keyEvent(126)), "Other windows must retain their keys")

        window.hasKeyboardFocus = false
        XCTAssertFalse(canvas.handleKeyboardEvent(keyEvent(49, window: window)))
        window.hasKeyboardFocus = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        container.addSubview(text)
        window.makeFirstResponder(text)
        XCTAssertFalse(canvas.handleKeyboardEvent(keyEvent(49, window: window)))
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        container.addSubview(slider)
        window.makeFirstResponder(slider)
        XCTAssertFalse(canvas.handleKeyboardEvent(keyEvent(126, window: window)), "Focused controls retain native arrow handling")
        canvas.focusForPlayback()
        XCTAssertTrue(window.firstResponder === canvas, "Clicking the video must move focus out of sidebar or slider controls")
        NSApp.sendEvent(keyEvent(126, window: window))
        XCTAssertEqual(actions, [.togglePause, .volumeUp])
        window.makeFirstResponder(text)
        canvas.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === text, "Layout updates must not steal editing focus")
        window.makeFirstResponder(nil)
        canvas.isHidden = true
        XCTAssertFalse(canvas.handleKeyboardEvent(keyEvent(126, window: window)))
        canvas.isHidden = false
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        XCTAssertFalse(canvas.handleKeyboardEvent(keyEvent(49, window: window)))
        window.endSheet(sheet)
        sheet.orderOut(nil)
        canvas.removeFromSuperview()
        NSApp.sendEvent(keyEvent(49, window: window))
        XCTAssertEqual(actions, [.togglePause, .volumeUp], "Detached playback must remove the monitor")
    }

    func testKeyboardControlsRealPlaybackAndRemainSingleAfterFullscreenReparent() async throws {
        let defaults = UserDefaults.standard
        let oldStep = defaults.object(forKey: HawkConfig.PLAY_TIME_STEP)
        let oldVolume = defaults.object(forKey: HawkConfig.PLAY_VOLUME)
        defaults.set(3, forKey: HawkConfig.PLAY_TIME_STEP)
        defer {
            defaults.set(oldStep, forKey: HawkConfig.PLAY_TIME_STEP)
            defaults.set(oldVolume, forKey: HawkConfig.PLAY_VOLUME)
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        let controller = MPVPlayerController()
        let presentation = ResizePresentation()
        let host = NSHostingView(rootView: ResizeHarness(url: url, controller: controller, presentation: presentation))
        let window = KeyboardTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { controller.stop(); window.orderOut(nil); window.contentView = nil }
        try await waitUntil(controller) { controller.durationSeconds > 0 && controller.isPlaying }
        window.makeFirstResponder(nil)
        NSApp.sendEvent(keyEvent(49, window: window))
        try await waitUntil(controller) { !controller.isPlaying }
        controller.seek(to: 2)
        try await waitUntil(controller) { abs(controller.currentTimeSeconds - 2) < 0.2 }
        NSApp.sendEvent(keyEvent(124, window: window))
        try await waitUntil(controller) { abs(controller.currentTimeSeconds - 5) < 0.2 }
        NSApp.sendEvent(keyEvent(123, window: window))
        try await waitUntil(controller) { abs(controller.currentTimeSeconds - 2) < 0.2 }
        controller.setVolume(100)
        for fullscreen in [true, false, true, false] {
            presentation.fullScreen = fullscreen
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            window.makeFirstResponder(nil)
            NSApp.sendEvent(keyEvent(126, window: window))
            XCTAssertEqual(controller.volume, 105, "Fullscreen must have exactly one keyboard handler")
            NSApp.sendEvent(keyEvent(125, window: window))
            XCTAssertEqual(controller.volume, 100)
        }
        controller.setVolume(198)
        NSApp.sendEvent(keyEvent(126, window: window))
        XCTAssertEqual(controller.volume, 200)
        controller.setVolume(2)
        NSApp.sendEvent(keyEvent(125, window: window))
        XCTAssertEqual(controller.volume, 0)
        NSApp.sendEvent(keyEvent(49, window: window))
        try await waitUntil(controller) { controller.isPlaying }
    }

    // XCTest hosts are not guaranteed foreground activation. Model only this
    // OS-owned flag; event dispatch, responder guards, view lifecycle and mpv
    // remain real. Installed-app verification covers actual keyboard focus.
    private final class KeyboardTestWindow: NSWindow {
        var hasKeyboardFocus = true
        override var isKeyWindow: Bool { hasKeyboardFocus }
    }

    private func keyEvent(_ code: UInt16, window: NSWindow? = nil,
                          modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                         context: nil, characters: code == 49 ? " " : "", charactersIgnoringModifiers: code == 49 ? " " : "",
                         isARepeat: repeated, keyCode: code)!
    }

    private final class ResizePresentation: ObservableObject {
        @Published var fullScreen = false
    }

    private struct ResizeHarness: View {
        let url: URL
        let controller: MPVPlayerController
        @ObservedObject var presentation: ResizePresentation
        var body: some View {
            ZStack {
                Color.black
                if !presentation.fullScreen {
                    MPVPlayerView(urlString: url.absoluteString, sharedController: controller)
                        .frame(width: 640, height: 360)
                }
            }
            .overlay {
                if presentation.fullScreen {
                    MPVPlayerView(urlString: url.absoluteString, sharedController: controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func waitUntil(_ controller: MPVPlayerController, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if let error = controller.errorMessage { XCTFail(error); throw MPVTestError.failed }
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("mpv timed out: decoder=\(controller.decoder), time=\(controller.currentTimeSeconds), tracks=\(controller.subtitles.tracks.count)")
        throw MPVTestError.failed
    }
    private enum MPVTestError: Error { case failed }
    #endif
}
