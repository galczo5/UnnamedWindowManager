# Window Position and Size Changes

All changes to managed application window position/size go through the Accessibility API (`AXUIElementSetAttributeValue`). Changes to overlay windows (borders, wallpaper, opacity, drop indicator) use `NSWindow` directly and are listed separately.

## Managed Application Windows

### TilingAnimationService

`Services/Tiling/TilingAnimationService.swift`

| Method | Lines | When |
|--------|-------|------|
| `tickAll()` | 126 (pos), 139 (size) | Every display-link tick while a tiling animation is in flight |
| `applyImmediate(ax:pos:size:positionOnly:)` | 186 (pos), 191 (size) | When animation duration is 0, current frame can't be read, the window was already animated once this cycle (`animatedOnce`), or `isBeingAnimated` is true |

Called from `TilingLayoutService` for every window in a tiling root.

### ScrollingAnimationService

`Services/Scrolling/ScrollingAnimationService.swift`

| Method | Lines | When |
|--------|-------|------|
| `tickAll()` | 253 (pos), 266 (size) | Every display-link tick while a scrolling animation is in flight |
| `applyImmediate(ax:pos:size:positionOnly:)` | 313 (pos), 318 (size) | Side windows in `animateScroll`, immediate-mode fallback in `animate`, or `isBeingAnimated` is true |

Called from `ScrollingLayoutService`. `animateScroll` handles scroll gestures; `animate` handles resize and scroll-to-center.

### WindowRestoreService

`Services/Window/WindowRestoreService.swift`

| Method | Lines | When |
|--------|-------|------|
| `restore(_:element:)` | 10 (pos), 14 (size) | Restores window to `preTileOrigin`/`preTileSize` when untiling |

No animation — immediate AX calls only.

## Overlay Windows (NSWindow)

These windows are created by the app itself; they are not managed application windows.

| Service | File | Method | What moves |
|---------|------|--------|------------|
| `FocusedWindowBorderService` | `Services/Border/FocusedWindowBorderService.swift` | `applyFull`, `moveOverlay` | Focus border overlay — tracks the active tiled window |
| `WallpaperService` | `Services/Wallpaper/WallpaperService.swift` | `show()` | Wallpaper window — sized to screen frame |
| `WindowOpacityService` | `Services/Window/WindowOpacityService.swift` | `dim(rootID:focusedHash:)` | Dim overlay — sized to screen frame |
| `TilingDropOverlay` | `Services/Tiling/TilingDropOverlay.swift` | `show(frame:belowWindow:)` | Drop-zone indicator — sized to drop target frame |
