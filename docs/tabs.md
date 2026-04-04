# Tab Recognition

macOS apps like Safari and Finder support native window tabs — multiple documents sharing a single window frame. The window manager needs to recognise these tab groups so that only one representative window per group is tiled, and tab switches update the tracked identity without disrupting the layout.

## How macOS Tabs Work at the CG Level

All tabs in a native tab group share the same `CGRect` bounds. The active tab is rendered on-screen; inactive tabs exist in `CGWindowListCopyWindowInfo` with identical frames but are not drawn. This property is the foundation of tab detection.

## Detection (TabDetector)

`TabDetector` queries `CGWindowListCopyWindowInfo` **without** `.optionOnScreenOnly`, so inactive tabs appear in the results. It then groups windows by PID and exact bounds match:

1. **Single-window query** — `tabSiblingHashes(of:pid:)` finds the target window's bounds, collects all same-PID windows with the same bounds, and returns their `CGWindowID` set. Returns empty if there are no siblings.
2. **Bulk filtering** — `filterTabDuplicates(wids:pid:)` takes a set of candidate window IDs for one PID, groups them by bounds, and keeps the smallest ID per group. Reports whether any tabs were found.

## Storage (WindowSlot)

Each `WindowSlot` stores two tab-related fields:

- `isTabbed: Bool` — whether the window belongs to a tab group.
- `tabHashes: Set<UInt>` — `CGWindowID`s of all windows in the group, including itself (auto-inserted via `didSet`).

Helper methods `isSameTabGroup(as:)` and `isSameTabGroup(hash:)` check membership.

## When Tabs Are Detected

### Tiling a single window (TileHandler)

After snapping a window, `TabDetector.tabSiblingHashes()` is called. If the window has tab siblings, `tabHashes` is populated and `isTabbed` is set. If a managed window from the same PID is already tracked and is either off-screen or a known tab sibling, the slot identity is swapped rather than adding a duplicate.

### Tiling all windows (TileAllHandler / ScrollAllHandler)

Before tiling, `TabDetector.filterTabDuplicates()` deduplicates per tab group so only one window per group enters the layout. All resulting slots are marked as tabbed if any tabs were found.

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
4. Queries fresh tab siblings from `TabDetector`.
5. Registers AX notifications on the new window element.

### ReapplyHandler

During layout reapplication, if a managed window's `CGWindowID` is no longer on-screen, the handler checks whether it became an inactive tab. It enumerates AX windows for the same PID looking for an unmanaged on-screen sibling and calls `swapTab()` if found.

## Key Invariant

A tab switch never changes the layout. Only the window identity (AX element reference and `CGWindowID` hash) is swapped; the slot's position, size, and fraction in the tree remain untouched.
