# Desktop Recognition

The app does not use explicit macOS Space IDs or private APIs. Instead, desktops are recognized **implicitly through window visibility**.

## Core Idea

A "desktop" is whatever set of windows macOS reports as on-screen right now. The app queries `CGWindowListCopyWindowInfo` with the `.optionOnScreenOnly` flag, which returns only windows visible on the active space. By checking which stored layout roots contain visible windows, the app determines which root belongs to the current desktop.

## Window Visibility Cache

`OnScreenWindowCache` wraps the CG call and caches results for ~50 ms. Its key method, `visibleHashes()`, returns the set of `CGWindowID` values currently on-screen. This set is the single source of truth for "which desktop am I on?"

## Mapping Windows to Roots

Layout roots (`TilingRootSlot`, `ScrollingRootSlot`) live in `SharedRootStore.roots`, keyed by UUID. None of these UUIDs correspond to a macOS space — they are internal identifiers.

To find the active root, `TilingRootStore.visibleRootID()` and `ScrollingRootStore.visibleScrollingRootID()` iterate all stored roots, collect their leaf windows, and check whether any leaf hash appears in `OnScreenWindowCache.visibleHashes()`. The first root with a visible leaf is the root for the current desktop.

Each desktop can have at most one tiling root and one scrolling root. `SharedRootStore.activeRootType` tracks which layout mode (tiling or scrolling) is active on the current desktop.

## Space Change Detection

`SpaceChangeObserver` listens to `NSWorkspace.activeSpaceDidChangeNotification`. When a space switch fires, it:

1. **Invalidates** the `OnScreenWindowCache` so visibility data is fresh.
2. **Detects displaced windows** — windows whose root has leaves split across two spaces (the user dragged them via Mission Control). These are untiled from their original root.
3. **Reapplies the layout** via `ReapplyHandler.reapplyAll()`, which only affects the newly-visible root.
4. **Updates `activeRootType`** by checking which root types have visible leaves.

## Displaced Window Handling

When a user moves a window to another space through Mission Control, the root that previously held it ends up with some leaves visible and some hidden. `SpaceChangeObserver.untileDisplacedWindows()` scans all roots for this condition and removes the visible orphans so they are no longer managed.

## Screens vs. Spaces

Screens (physical monitors) and spaces (virtual desktops) are handled separately. `ScreenChangeObserver` reacts to monitor connect/disconnect and resolution changes. `SpaceChangeObserver` reacts to virtual desktop switches. Both trigger `ReapplyHandler.reapplyAll()`.

## Known Limitations

- **No explicit space IDs.** The app cannot distinguish two empty desktops — only desktops with managed windows.
- **CGWindowList cross-space bleed.** On some macOS versions, `.optionOnScreenOnly` briefly returns windows from the previous space during a transition. The app handles this by keeping the current `activeRootType` unchanged when both tiling and scrolling roots appear visible simultaneously.
