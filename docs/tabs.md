# Tab Recognition

macOS apps like Safari and Finder support native window tabs — multiple documents sharing a single window frame. The window manager needs to recognise these tab groups so that only one representative window per group is tiled, and tab switches update the tracked identity without disrupting the layout.

## How macOS Tabs Appear via AX

Each tab in a native tab group is a separate `AXUIElement` window sharing the same `CGRect` bounds, but the authoritative source is the accessibility hierarchy: a window with tabs contains an `AXTabGroup` element whose children are `AXRadioButton` elements — one per tab. The selected radio button's `AXValue` is truthy; every tab's `AXTitle` matches the corresponding sibling window's title.

## Detection (TabRecognizer + WindowWindowTabDetector)

`TabRecognizer` takes a list of AX windows (one PID's full window list) and produces `[AXWindowImproved]` entries, each holding a representative (selected) tab AX element plus all sibling AX elements in the group. It finds the `AXTabGroup` via a depth-limited subtree walk (≤ 3 levels) and resolves radio-button entries back to the sibling windows by title.

`WindowWindowTabDetector` is a thin adapter that exposes the same API the rest of the app uses:

1. **Single-window query** — `tabSiblingHashes(of:pid:)` enumerates AX windows for the PID, runs the recognizer, and returns the `CGWindowID` set of whichever group contains the requested hash. Empty if the window has no tab group.
2. **Bulk filtering** — `filterTabDuplicates(wids:pid:)` takes a set of candidate window IDs for one PID, drops duplicates per tab group, and keeps the selected tab as the representative (falling back to the smallest wid if that fails). Reports whether any tabs were found.

Because detection is grounded in the AX tab group, two unrelated windows that happen to share identical frames are never treated as a tab group.

## Storage (WindowSlot)

Each `WindowSlot` stores two tab-related fields:

- `isTabbed: Bool` — whether the window belongs to a tab group.
- `tabHashes: Set<UInt>` — `CGWindowID`s of all windows in the group, including itself (auto-inserted via `didSet`).

Helper methods `isSameTabGroup(as:)` and `isSameTabGroup(hash:)` check membership.

## When Tabs Are Detected

### Tiling a single window (TileHandler)

After snapping a window, `WindowTabDetector.tabSiblingHashes()` is called. If the window has tab siblings, `tabHashes` is populated and `isTabbed` is set. If a managed window from the same PID is already tracked and is either off-screen or a known tab sibling, the slot identity is swapped rather than adding a duplicate.

### Tiling all windows (TileAllHandler / ScrollAllHandler)

Before tiling, `WindowTabDetector.filterTabDuplicates()` deduplicates per tab group so only one window per group enters the layout. All resulting slots are marked as tabbed if any tabs were found.

## Tab Switching

When the user switches to a different tab, a new `CGWindowID` becomes active. The app detects this in two places:

### FocusObserver

When a window gains focus and is not managed, `FocusObserver` checks whether it's a tab sibling of any managed window (by hash lookup or fresh bounds-based detection). If so, it calls `swapTab()` on the `ResizeObserver`. Includes retry polling in case `CGWindowList` hasn't settled yet.

### ResizeObserver

When an AX notification arrives for an untracked window, `ResizeObserver.handle()` checks for tab group membership and calls `swapTab()` if matched.

`swapTab()` updates the slot identity in place:

1. Removes AX notifications from the old window element.
2. Cleans up tracking for the old window.
3. Updates the slot tree to reference the new window's identity — layout position and size are preserved.
4. Queries fresh tab siblings from `WindowTabDetector`.
5. Registers AX notifications on the new window element.

### ReapplyHandler

During layout reapplication, if a managed window's `CGWindowID` is no longer on-screen, the handler checks whether it became an inactive tab. It enumerates AX windows for the same PID looking for an unmanaged on-screen sibling and calls `swapTab()` if found.

## Key Invariant

A tab switch never changes the layout. Only the window identity (AX element reference and `CGWindowID` hash) is swapped; the slot's position, size, and fraction in the tree remain untouched.
