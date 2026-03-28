# Unnamed Window Manager

A tiling window manager for macOS, running as a menu bar app.

## What is a tiling window manager?

A tiling window manager automatically arranges application windows into non-overlapping tiles that fill your screen. Instead of manually dragging and resizing windows, you tile them and the manager divides the available space between them. Add a window, remove a window, or change the layout — everything repositions and resizes to fit.

## Features

### Tiling layout

Windows are organized into a binary split tree. Each split can be horizontal or vertical, and you can flip the orientation at any time. Windows are tiled in order and the screen is divided equally among them. Resize one window manually and the rest adjust to fill the remaining space.

### Scrolling layout

An alternative three-zone layout with a focused center window and stacked sidebars on the left and right. Navigate left and right to cycle which window is in the center.

### Drag-and-drop reordering

Drag a tiled window onto another to swap their positions, or drag it into an edge drop zone (left, right, top, bottom) to insert it at that position. A translucent overlay previews where the window will land.

### Keyboard-driven navigation

All operations have configurable keyboard shortcuts:

- **Directional focus** — move focus to the nearest window in any direction
- **Directional swap** — swap the focused window with its neighbor
- **Tile / Untile** — add or remove the focused window from the layout
- **Tile All** — batch-tile all visible windows
- **Scroll / Unscroll** — add or remove the focused window from a scrolling layout
- **Scroll All** — batch-scroll all visible windows
- **Flip orientation** — toggle horizontal/vertical split
- **Custom commands** — bind any keyboard shortcut to a shell command

### Inactive window dimming

Optionally dims unfocused windows with a configurable overlay color, opacity, and animation duration.

### Smooth animations

Window position and size changes are animated with ease-out interpolation. Animation duration is configurable.

### Multi-monitor support

Each display gets its own independent layout. Screen connection, disconnection, and resolution changes are detected automatically and layouts reflow to match.

### Window restore

When a window is untiled, it returns to its original position and size from before it was tiled.

### Resize validation

Windows that refuse a resize (due to minimum size constraints) are detected, corrected, and reported via system notification. Persistent refusers are automatically untiled.

### Configurable gaps and sizing

All layout parameters are adjustable in `~/.config/unnamed/config.yml`:

- Inner gap between windows
- Independent outer gaps on each screen edge (left, right, top, bottom)
- Maximum width and height fractions
- Scrolling center window width fraction
- Drop zone sizes
- Overlay corner radius, border width, and color

### Menu bar controls

Everything is accessible from the menu bar icon: tile, untile, scroll, unscroll, flip orientation, reset layout, refresh, open/reload/reset config, and debug logging.

## Configuration

The config file lives at `~/.config/unnamed/config.yml` and is created with defaults on first launch. You can open, reload, or reset it from the menu bar. All keyboard shortcuts, layout parameters, gap sizes, overlay styling, and behavior toggles are configurable.

## Built with AI

This app was built with [Claude Code](https://claude.ai/code) by [Anthropic](https://anthropic.com).
