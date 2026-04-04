# Events

## System Events

- **App Activated** — Starts observing the app's windows for creation and focus changes; applies window dimming
  - WindowCreationObserver
  - FocusObserver
- **App Terminated** — Removes accessibility observers and cleans up tracking for the terminated app
  - WindowCreationObserver
  - FocusObserver
- **App Will Terminate** — Removes wallpapers, untiles and unscrolls all windows across all spaces before exit
  - AppDelegate
- **Space Changed** — Untiles windows that were displaced to another space, reflows layout on the current space, refreshes menu state
  - SpaceChangeObserver
  - UnnamedWindowManagerApp
- **Screen Parameters Changed** — Clears layout cache, recomputes visible root sizes, updates wallpaper, reapplies layout (e.g. monitor plugged/unplugged, resolution change)
  - ScreenChangeObserver
- **Key Down** — Matches global keyboard shortcut; if matched, consumes the event and executes the bound action
  - KeybindingService
- **Display Link Tick** — Drives frame-accurate window move/resize animations (both tiling and scrolling use their own CVDisplayLink)
  - AnimationService
  - ScrollingAnimationService

## Window Events

- **Window Created** — Logs the new window, triggers auto-mode tiling if enabled
  - WindowCreationObserver
- **Window Moved** — Schedules layout reapply via drag-reapply scheduler (also tracked on tab siblings)
  - ResizeObserver
- **Window Resized** — Schedules layout reapply via drag-reapply scheduler; removes window if it entered fullscreen
  - ResizeObserver
- **Window Miniaturized** — Removes the window from the tiling layout
  - ResizeObserver
- **Window Destroyed** — Removes the window from the tiling layout and cleans up observers
  - ResizeObserver
- **Window Title Changed** — Ignored, no action taken
  - ResizeObserver
- **Focused Window Changed** — Posts internal focus notification, applies window dimming, detects tab switches
  - FocusObserver
- **Main Window Changed** — Same as focused window changed
  - FocusObserver
- **Window Occlusion Changed** — Pauses or resumes GIF wallpaper animation based on visibility
  - GifImageView

## Internal Events

- **Tile State Changed** — Refreshes menu bar state (posted after untile, unscroll, or reapply)
  - UnnamedWindowManagerApp
- **Window Focus Changed** — Refreshes menu bar state, triggers auto-mode focus change handling
  - UnnamedWindowManagerApp
  - WindowCreationObserver
