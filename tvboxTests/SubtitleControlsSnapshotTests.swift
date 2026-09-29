#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TVBox

@MainActor
final class SubtitleControlsSnapshotTests: XCTestCase {
    func testRenderSystemAndVLCSubtitleControls() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        try snapshot(AVPlayerContentView(urlString: url.absoluteString,
                                        onToggleFullScreen: {}, canPlayNext: true, onPlayNext: {}), name: "system")
        #if canImport(Libmpv)
        // Explicit ownership and an awaited native shutdown are required here.
        // XCTest can exit immediately after this test, while queued teardown is
        // still compiling shaders; C++ global destructors then race the VO.
        let controller = MPVPlayerController()
        do {
            try snapshot(MPVPlayerView(urlString: url.absoluteString,
                                      onToggleFullScreen: {}, canPlayNext: true, onPlayNext: {},
                                      sharedController: controller), name: "mpv")
            try snapshot(MPVPlayerView(urlString: url.absoluteString,
                                      onToggleFullScreen: {}, canPlayNext: true, onPlayNext: {},
                                      sharedController: controller), name: "mpv-compact", width: 640)
        } catch {
            await controller.stopAndWaitForTesting()
            throw error
        }
        await controller.stopAndWaitForTesting()
        #endif
        #if canImport(VLCKitSPM)
        try snapshot(VLCVodPlayerView(urlString: url.absoluteString,
                                     onToggleFullScreen: {}, canPlayNext: true, onPlayNext: {}), name: "vlc")
        #endif
        #if canImport(Libmpv)
        XCTAssertEqual(MPVPlayerController.pendingShutdownsForTesting, 0,
                       "Snapshot tests must drain native rendering before the XCTest process exits")
        #endif
    }

    private func snapshot<V: View>(_ view: V, name: String, width: CGFloat = 960) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 540)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name) subtitle controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/tvbox-subtitle-\(name).png"))
    }
}
#endif
