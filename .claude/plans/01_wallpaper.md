# Plan: 01_wallpaper — Configurable Desktop Wallpaper

## Checklist

- [x] Add `WallpaperConfig` struct to ConfigData
- [x] Add wallpaper accessors to Config
- [x] Add wallpaper section to ConfigLoader format
- [x] Create WallpaperWindow (borderless NSWindow for image display)
- [x] Create GifImageView (NSView that plays animated GIFs via CGImageSource)
- [x] Create WallpaperService (lifecycle: show/hide/reload per screen)
- [x] Start wallpaper on app launch and tear down on quit
- [x] React to config reload and screen changes
- [x] Update CODE.md

---

## Context / Problem

The app currently manages window tiling/scrolling but has no concept of a desktop wallpaper. macOS provides its own wallpaper, but users want a custom overlay wallpaper rendered by the app — supporting PNG, JPG, and animated GIF. The wallpaper window must sit behind all other windows, cover the full screen, and survive space switches and display changes.

---

## Behaviour spec

- **Config**: new `config.wallpaper` section with `enabled` (bool), `path` (string to image file), and `scaling` (`fill`, `fit`, `stretch`, `center`).
- **Window level**: `NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1)` — one level above the real desktop so it covers the macOS wallpaper but stays behind everything else.
- **Multi-screen**: one wallpaper window per connected screen.
- **Animated GIF**: decode frames via `CGImageSource`, advance with a `CADisplayLink`-style timer respecting per-frame delays from GIF metadata.
- **Static images** (PNG/JPG): displayed via `NSImageView` with the chosen scaling mode.
- **Lifecycle**: appears when `enabled: true` and `path` points to a valid file. Hidden (not destroyed) when disabled. Refreshed on config reload. Repositioned on screen parameter changes.
- **Teardown**: wallpaper windows are removed on app quit (they are owned by the process, so this is automatic, but explicit cleanup keeps AppDelegate consistent).

---

## Files to create / modify

| File | Action |
|------|--------|
| `Config/ConfigData.swift` | Modify — add `WallpaperConfig` struct and wire into defaults/missingKeys/merge |
| `Config/Config.swift` | Modify — add static wallpaper accessors |
| `Config/ConfigLoader.swift` | Modify — add wallpaper section to `format()` |
| `Services/Wallpaper/WallpaperWindow.swift` | **New file** — borderless NSWindow pinned to desktop level |
| `Services/Wallpaper/GifImageView.swift` | **New file** — NSView that decodes and animates GIF frames |
| `Services/Wallpaper/WallpaperService.swift` | **New file** — singleton managing wallpaper windows per screen |
| `UnnamedWindowManagerApp.swift` | Modify — start WallpaperService in `init()` |
| `AppDelegate.swift` | Modify — tear down wallpaper on quit |
| `Services/Observation/ScreenChangeObserver.swift` | Modify — notify WallpaperService on screen changes |
| `UnnamedWindowManager/CODE.md` | Modify — add Wallpaper section |

---

## Implementation Steps

### 1. Config: WallpaperConfig

Add to `ConfigData.swift`:

```swift
struct WallpaperConfig: Codable {
    var enabled: Bool?
    var path: String?
    var scaling: String?   // "fill", "fit", "stretch", "center"
}
```

Add `var wallpaper: WallpaperConfig?` to `ConfigSection`.

Defaults: `enabled: false`, `path: ""`, `scaling: "fill"`.

Wire into `missingKeys` and `mergedWithDefaults()` following the existing pattern.

In `Config.swift`, add:

```swift
static var wallpaperEnabled: Bool   { shared.s.wallpaper!.enabled! }
static var wallpaperPath: String    { shared.s.wallpaper!.path! }
static var wallpaperScaling: String { shared.s.wallpaper!.scaling! }
```

In `ConfigLoader.format()`, add a `wallpaper:` YAML section between `behavior:` and `shortcuts:`.

### 2. WallpaperWindow

A minimal borderless `NSWindow` subclass (or factory) that:

- Uses `styleMask: .borderless`, `isOpaque: true`, `backgroundColor: .black`.
- Sets `level` to `NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1)`.
- Sets `collectionBehavior = [.canJoinAllSpaces, .stationary]` so it appears on every space and stays put during Mission Control.
- `ignoresMouseEvents = true` — clicks pass through to the real desktop.
- Sizes itself to the screen's full `frame` (not `visibleFrame`, since wallpaper should cover the menu bar area too).

### 3. GifImageView

An `NSView` subclass that:

- Takes a file `URL`, creates a `CGImageSource`, reads `CGImageSourceGetCount` for frame count.
- For single-frame sources, just sets a `CALayer.contents` to the first `CGImage`.
- For multi-frame sources, reads per-frame delay from `kCGImagePropertyGIFUnclampedDelayTime` / `kCGImagePropertyGIFDelayTime` in `kCGImagePropertyGIFDictionary`.
- Advances frames using a `DispatchSourceTimer` (CVDisplayLink is overkill; a repeating timer at the GIF's frame rate is sufficient). On each tick, sets `layer.contents` to the next `CGImage`.
- Provides `start()` / `stop()` to control playback and a `scaling` property to control image gravity (`resizeAspectFill`, `resizeAspect`, `resize`, `center` mapping to the four config modes).

### 4. WallpaperService

Singleton that manages one wallpaper window per screen.

```swift
final class WallpaperService {
    static let shared = WallpaperService()
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
}
```

Key methods:

- `apply()` — reads config; if `enabled` and `path` is a valid file, creates/updates a wallpaper window for each `NSScreen`. Removes windows for disconnected screens. If `!enabled`, calls `removeAll()`.
- `removeAll()` — orders out and clears all wallpaper windows.
- `screenChanged()` — called by `ScreenChangeObserver`; repositions/resizes existing windows to match new screen frames, or adds/removes windows if screens were connected/disconnected.

`apply()` determines the image type by extension: `.gif` gets a `GifImageView`, anything else gets an `NSImageView` with `imageScaling` set from the config scaling mode.

### 5. Lifecycle wiring

**`UnnamedWindowManagerApp.init()`**: add `WallpaperService.shared.apply()` after existing setup.

**`AppDelegate.applicationWillTerminate()`**: add `WallpaperService.shared.removeAll()`.

**Config reload** (in `UnnamedWindowManagerApp.body`, the "Reload config file" button): add `WallpaperService.shared.apply()` after `Config.shared.reload()`.

**`ScreenChangeObserver.screenParametersChanged()`**: add `WallpaperService.shared.screenChanged()`.

---

## Key Technical Notes

- `CGWindowLevelForKey(.desktopWindow) + 1` is the correct level — the macOS desktop icons live at `.desktopWindow`, so +1 covers the wallpaper but stays below normal windows and the dock.
- `collectionBehavior: [.canJoinAllSpaces, .stationary]` prevents the wallpaper from sliding during space transitions. `.stationary` is critical — without it, the window would animate with the space switch.
- `NSScreen.frame` includes the menu bar; `NSScreen.visibleFrame` excludes it. Wallpaper must use `.frame` to cover the entire display.
- GIF frame delays below 0.02s should be clamped to 0.1s (browser convention for GIFs with 0 or near-0 delays).
- `CGImageSource` is the right API — `NSImage` can load GIFs but does not expose individual frames for animation.
- The wallpaper window must be `isOpaque = true` (not transparent) for best performance — compositing a full-screen transparent window is expensive.
- `path` supports `~` — expand with `NSString.expandingTildeInPath` before use.

---

## Verification

1. Set `wallpaper.enabled: true` and `wallpaper.path` to a PNG file — wallpaper appears covering the full screen behind all windows
2. Set path to a JPG — same behaviour
3. Set path to an animated GIF — animation plays smoothly
4. Change `scaling` between `fill`, `fit`, `stretch`, `center` and reload config — image scaling updates
5. Set `enabled: false` and reload — wallpaper disappears
6. Set an invalid path — no crash, no wallpaper shown
7. Connect/disconnect an external display — wallpaper adjusts to available screens
8. Switch Spaces — wallpaper remains visible on all spaces without sliding
9. Click where the wallpaper is — clicks pass through to the desktop
10. Quit the app — wallpaper windows disappear
