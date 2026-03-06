# Plan: 11_menu_bar_organized_label — Show "[organized]" text in menu bar when windows are snapped

## Checklist

- [ ] Add `isOrganized: Bool` to `MenuState` and update `refresh()`
- [ ] Subscribe `MenuState` to a snap-state `NotificationCenter` notification
- [ ] Post the notification from `ReapplyHandler.reapplyAll()` and `UnsnapHandler.unsnap()`
- [ ] Switch `MenuBarExtra` to the `label:` closure form with conditional `Text("[organized]")`

---

## Context / Problem

The menu bar icon currently always shows a static icon with no text. The user wants the label `[organized]` to appear next to the icon whenever at least one window is snapped on the current screen, and no text otherwise.

The existing `MenuState.refresh()` already queries orientation state; the same pattern can check `SnapService.shared.snapshotVisibleRoot() != nil`.

The menu bar label is **always rendered**, not just when the menu is open, so an `onAppear`-only refresh is insufficient. The label must also update reactively when snap state changes outside the menu.

---

## Behaviour Spec

| Condition | Label |
|-----------|-------|
| No snapped windows on current screen | icon only |
| ≥ 1 snapped window on current screen | icon + `[organized]` |

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add `isOrganized`, label closure, notification subscription |
| `UnnamedWindowManager/System/ReapplyHandler.swift` | Modify — post notification at end of `reapplyAll()` |
| `UnnamedWindowManager/System/UnsnapHandler.swift` | Modify — post notification after removing last window (no `reapplyAll` guard) |

---

## Implementation Steps

### 1. Define a notification name

Add an extension in `UnnamedWindowManagerApp.swift` (or a shared constants file) so there is a single source of truth:

```swift
extension Notification.Name {
    static let snapStateChanged = Notification.Name("snapStateChanged")
}
```

### 2. Extend `MenuState` with `isOrganized`

Add the property and update `refresh()` to set it:

```swift
@Observable
final class MenuState {
    var parentOrientation: Orientation? = nil
    var isOrganized: Bool = false

    func refresh() {
        parentOrientation = OrientFlipHandler.parentOrientation()
        isOrganized = SnapService.shared.snapshotVisibleRoot() != nil
    }
}
```

### 3. Subscribe to snap-state notifications in the App

In `UnnamedWindowManagerApp`, observe the notification and call `menuState.refresh()`:

```swift
var body: some Scene {
    MenuBarExtra {
        // ... menu items unchanged ...
    } label: {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.split.2x1")
            if menuState.isOrganized {
                Text("[organized]")
            }
        }
    }
    .menuBarExtraStyle(.menu)
    .onChange(of: true) { // placeholder — use task/onAppear on label
        // see note below
    }
}
```

Because `MenuBarExtra` scenes don't support `.task` directly, subscribe using `onReceive` on the label view, or use a dedicated `@State` observer set up in `init`. The cleanest approach: keep the existing `onAppear` on menu items for menu-open refresh, **and** add an `onReceive` on the label `HStack`:

```swift
} label: {
    HStack(spacing: 4) {
        Image(systemName: "rectangle.split.2x1")
        if menuState.isOrganized {
            Text("[organized]")
        }
    }
    .onAppear { menuState.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: .snapStateChanged)) { _ in
        menuState.refresh()
    }
}
```

Remove the `onAppear` from the menu items (it was only needed for `parentOrientation`; the label `onAppear` now covers both).

### 4. Post the notification after snap state changes

`ReapplyHandler.reapplyAll()` is the terminal step for every snap and organize operation. Add a main-thread post there:

```swift
static func reapplyAll() {
    // ... existing code unchanged ...
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        ResizeObserver.shared.reapplying.subtract(allWindows)
    }
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .snapStateChanged, object: nil)
    }
}
```

`UnsnapHandler.unsnap()` calls `removeAndReflow` then `reapplyAll()`, so it is covered. However, when the last window is removed, `reapplyAll()` still runs (with zero leaves) — the notification will still fire, and `refresh()` will set `isOrganized = false`. No extra posting needed in `UnsnapHandler`.

---

## Key Technical Notes

- `snapshotVisibleRoot()` takes a `store.queue.sync` read lock — safe to call from the main thread.
- The label `HStack` `.onAppear` fires once when the menu bar item is first rendered, which handles the initial state.
- `onReceive` on the label view keeps receiving for the lifetime of the app since the label is always in the view hierarchy.
- `ReapplyHandler.reapplyAll()` is called from AX callbacks (background thread) via `ResizeObserver`. The `DispatchQueue.main.async` post ensures the notification is delivered on the main thread.
- Do not post from `SnapService` internals — it runs inside a `queue.sync(flags: .barrier)` block and posting there would be redundant and potentially nested.

---

## Verification

1. Launch app with no snapped windows → menu bar shows icon only, no text.
2. Snap a window (Snap menu item) → label changes to icon + `[organized]` without reopening the menu.
3. Open the menu and check orientation button still works correctly.
4. Unsnap the last window → label reverts to icon only.
5. Run Organize → all visible windows snapped, label shows `[organized]`.
6. Quit and relaunch → label shows `[organized]` if windows were previously snapped and root is re-detected (or icon only if state is fresh).
