# MPVKit MoltenVK resize fix

Pinned to MPVKit 1.0.0 / mpv 0.41.0. This directory contains the Metal Vulkan
context from MPVKit's `0001-player-add-moltenvk-context.patch`, required mpv
internal headers, and Vulkan-Headers v1.3.275 declarations. Original hashes and
upstream versions are recorded in `upstream-sha256.json`; original file notices
and licenses are retained.

## Failure and fix

The original context reads `CAMetalLayer.drawableSize` only on video reconfig.
Its control callback does not handle later surface size changes. On fullscreen
entry, the layer becomes 2400×1600 pixels while the VO remains 1280×720, leaving
video in the upper-left of an otherwise black surface.

The replacement context compares drawable size during `VOCTRL_CHECK_EVENTS`,
resizes the Vulkan context and emits resize/expose events. A KVO observer wakes
the VO when drawable size changes, including while paused. The Swift Metal
layer setter uses Objective-C dynamic dispatch so these notifications occur.
The observer holds a lock around its VO pointer; teardown clears that pointer
and unregisters the observer before destroying the GPU and VO. Late callbacks
therefore cannot reference a freed VO. All GPU resizing stays on the VO thread.

The macOS target compiles only `video/out/vulkan/context_moltenvk.m`. Its context
symbol satisfies the static archive reference before the original member is
extracted, as with the existing CoreAudio backport. No dependency-cache changes
or runtime symbol patching are used. Keep internal structure layouts and helper
signatures aligned with the pinned mpv binary; review/remove both backports
when upgrading MPVKit.

## Build details

- Shared mpv utility headers and macOS configuration come from `Vendor/MPVCoreAudio` at the same tag.
- Framework includes use MPVKit's `Libplacebo` / `Libavutil` names.
- Vulkan declarations replace the unavailable MoltenVK SDK include; the actual
  MoltenVK implementation still comes from the pinned MPVKit binary.
- This translation unit uses manual Objective-C ownership and disables implicit
  modules: Libplacebo's umbrella includes Windows-only headers that are not used
  by this backend. Other application sources retain their existing settings.
- Debug paths are mapped to relative paths for bundle privacy.

## Regression checks

`MPVPlayerTests.testFullscreenReparentAndWindowResizeKeepMetalSurfaceAtCanvasSize`
uses a real SwiftUI inline/fullscreen host and H.264 fixture. It compares the
actual mpv `osd-dimensions` with the drawable pixel size while playing and paused,
checks repeated fullscreen transitions, and retains session identity, selected
subtitles, delay, and VideoToolbox decoding. Layout-only checks previously passed
while the actual renderer was stale; the debug-only query locks this down.

The KVO test verifies a Swift drawable-size assignment reaches native observers.
The teardown test resizes retained layers during and after repeated session
shutdown. Run these alongside the existing audio-device teardown and playback
tests, then build Universal 2 and audit/sign the installation bundle.

## Upstream sources

- https://github.com/mpvkit/MPVKit/tree/1.0.0
- https://github.com/mpv-player/mpv/tree/v0.41.0
- https://github.com/KhronosGroup/Vulkan-Headers/tree/v1.3.275
