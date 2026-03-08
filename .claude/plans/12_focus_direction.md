# Plan: 12_focus_direction — Focus window by direction (left/right/up/down)

## Checklist

- [x] Add focusLeft/Right/Up/Down to ConfigData.ShortcutsConfig
- [x] Add focusLeft/Right/Up/Down to Config
- [x] Add focusLeft/Right/Up/Down to ConfigData defaults, missingKeys, mergedWithDefaults
- [x] Add focusLeft/Right/Up/Down to ConfigLoader YAML template
- [x] Create FocusDirectionService with spatial navigation helpers
- [x] Create FocusLeftHandler
- [x] Create FocusRightHandler
- [x] Create FocusUpHandler
- [x] Create FocusDownHandler
- [x] Register four new shortcuts in KeybindingService

---

## Context / Problem

There is no keyboard shortcut to move focus between snapped windows. The user must click or Cmd-Tab. We want ctrl+opt+arrow to focus the nearest snapped window in the given direction.

---

## Analysis — Behaviour by slot type

The slot tree is recursive: a `RootSlot` has children which are `Slot` values, each of which can be a `WindowSlot` (leaf), `HorizontalSlot`, or `VerticalSlot` (containers). Navigation must work across all nesting levels.

**Simple horizontal root (two windows side-by-side):**

```
Root (horizontal)
├── Window A
└── Window B
```

Focus A → right → B. Focus B → left → A. Up/down → no-op (no window above or below).

**Simple vertical root (two windows stacked):**

```
Root (vertical)
├── Window A
└── Window B
```

Focus A → down → B. Focus B → up → A. Left/right → no-op.

**Mixed nesting (horizontal root with a vertical split):**

```
Root (horizontal)
├── Window A
└── Vertical
    ├── Window B
    └── Window C
```

Focus A → right → B (B is the closest window to the right of A's center). Focus B → left → A. Focus B → down → C. Focus C → up → B. Focus C → left → A.

**Deeply nested:**

```
Root (horizontal)
├── Vertical
│   ├── Window A
│   └── Window B
└── Vertical
    ├── Window C
    └── Window D
```

Focus A → right → C (nearest to the right of A's center). Focus A → down → B. Focus D → left → B (nearest to the left of D's center, matching vertical position). Focus C → down → D.

**Single window:** All directions are no-ops.

### Algorithm: spatial overlap-based selection

Rather than walking the tree structurally (sibling-then-parent), use a **spatial** approach:

1. Compute the bounding rect of every leaf by walking the tree the same way `LayoutService` does (cursor + orientation).
2. From the focused window's rect, filter leaves that lie in the requested direction (e.g., "right" means candidate center.x > source center.x).
3. Among candidates, pick by **axis overlap**: the candidate with the greatest overlap on the perpendicular axis wins. Ties are broken by primary-axis distance.

Overlap-based sorting handles tall/wide windows correctly. For example, a full-height left window pressing right should focus the tallest (most Y-overlapping) right neighbour, not a small corner window that happens to be closer by center-point distance.

**Direction filter and sort rules:**

| Direction | Filter                             | Sort: primary                        | Sort: tiebreak               |
|-----------|------------------------------------|--------------------------------------|------------------------------|
| Left      | candidate.centerX < source.centerX | most Y overlap with source (desc)    | smallest abs(deltaX)         |
| Right     | candidate.centerX > source.centerX | most Y overlap with source (desc)    | smallest abs(deltaX)         |
| Up        | candidate.centerY < source.centerY | most X overlap with source (desc)    | smallest abs(deltaY)         |
| Down      | candidate.centerY > source.centerY | most X overlap with source (desc)    | smallest abs(deltaY)         |

**Edge case — no candidate:** If no leaf is in the requested direction, do nothing (no wrap-around).

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/ConfigData.swift` | Modify — add 4 shortcut fields |
| `UnnamedWindowManager/Config.swift` | Modify — add 4 static accessors |
| `UnnamedWindowManager/ConfigLoader.swift` | Modify — add 4 YAML keys to template |
| `UnnamedWindowManager/Services/FocusDirectionService.swift` | **New file** — shared spatial helpers (leaf rect computation, nearest-neighbor search) |
| `UnnamedWindowManager/System/FocusLeftHandler.swift` | **New file** — entry point for focus-left |
| `UnnamedWindowManager/System/FocusRightHandler.swift` | **New file** — entry point for focus-right |
| `UnnamedWindowManager/System/FocusUpHandler.swift` | **New file** — entry point for focus-up |
| `UnnamedWindowManager/System/FocusDownHandler.swift` | **New file** — entry point for focus-down |
| `UnnamedWindowManager/Services/KeybindingService.swift` | Modify — register 4 new shortcuts |

---

## Implementation Steps

### 1. Add config fields

Add `focusLeft`, `focusRight`, `focusUp`, `focusDown` (all `String?`) to `ShortcutsConfig`. Add them to `defaults` (default: `"ctrl+opt+left"` etc.), `missingKeys`, and `mergedWithDefaults`. Add corresponding `static var` accessors to `Config`. Add YAML keys/comments to the config template in `ConfigLoader`.

### 2. Create FocusDirectionService

New file `Services/FocusDirectionService.swift`. Contains the shared spatial logic:

- `leafRects(in: RootSlot) -> [(key: WindowSlot, rect: CGRect)]` — walks the tree identically to `LayoutService.applyLayout`, accumulating `(WindowSlot, CGRect)` pairs instead of setting AX attributes. Uses the same screen origin calculation.
- `nearest(from:direction:candidates:exclude:) -> WindowSlot?` — filters candidates by direction, picks nearest by perpendicular-axis distance.
- `activateWindow(_: WindowSlot)` — looks up the AX element from `ResizeObserver.shared.elements`, activates the owning app, and raises the window.

Also defines `enum FocusDirection { case left, right, up, down }`.

### 3. Create four handler files

Each handler is a small struct with a single static `func focus()` that:
1. Gets the frontmost focused window (same pattern as `SnapHandler.snap`)
2. Calls `FocusDirectionService` with the appropriate direction
3. Activates the result

```swift
// FocusLeftHandler.swift
struct FocusLeftHandler {
    static func focus() {
        FocusDirectionService.focus(.left)
    }
}
```

`FocusRightHandler`, `FocusUpHandler`, `FocusDownHandler` follow the same pattern.

### 4. Register shortcuts in KeybindingService

Add four entries to the `candidates` array:

```swift
(Config.focusLeftShortcut,  { FocusLeftHandler.focus() }),
(Config.focusRightShortcut, { FocusRightHandler.focus() }),
(Config.focusUpShortcut,    { FocusUpHandler.focus() }),
(Config.focusDownShortcut,  { FocusDownHandler.focus() }),
```

---

## Key Technical Notes

- Arrow keys must be matched by **key code**, not by character string. `NSEvent.charactersIgnoringModifiers` is unreliable for arrow keys when `ctrl` is held (returns a control character or empty string). Key codes are modifier-independent: left=123, right=124, down=125, up=126. `KeybindingService.Binding` carries an optional `keyCode: UInt16?` alongside the existing `key: String?`; arrow key tokens in `parse` populate `keyCode` instead of `key`.
- Arrow keys inject `.numericPad` and `.function` into `NSEvent.modifierFlags`. Strip both before comparing against the binding's modifiers (which never include them), otherwise the equality check always fails.
- `leafRects` must use the same origin/gap math as `LayoutService.applyLayout` to produce correct coordinates.
- `NSRunningApplication(processIdentifier:)` can return `nil` if the process has exited; guard against this.
- The `elements` map on `ResizeObserver` is main-thread-only; `FocusHandler.focus` is dispatched on main via `KeybindingService`, so this is safe.

---

## Verification

1. Snap two windows side by side → ctrl+opt+right moves focus from left to right window
2. Snap two windows stacked → ctrl+opt+down moves focus from top to bottom
3. Snap three windows (one left, two stacked right) → ctrl+opt+right from left enters the right column; ctrl+opt+up/down moves within the column; ctrl+opt+left returns to the left window
4. Focus the leftmost window → ctrl+opt+left is a no-op (no wrap)
5. Single snapped window → all directions are no-ops
6. No snapped windows → all directions are no-ops (no crash)
7. Custom shortcut in config.yml overrides the default
