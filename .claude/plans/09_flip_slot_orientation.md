# Plan: 09_flip_slot_orientation — Change Slot Orientation from Menu Bar

## Checklist

- [x] Add `findParentOrientation(of:in:)` to `SlotTreeService`
- [x] Add `flipParentOrientation(of:in:)` to `SlotTreeService`
- [x] Add `flipParentOrientation(_:screen:)` to `SnapService`
- [x] Create `System/OrientFlipHandler.swift`
- [x] Update `UnnamedWindowManagerApp.swift` with dynamic "Change to …" button

---

## Context / Problem

Users want to be able to toggle the orientation (horizontal ↔ vertical) of the container slot that holds the currently focused window. The top bar menu already has Snap / Unsnap / Organize — adding a "Change to vertical" / "Change to horizontal" button follows the same pattern. The label should reflect what the flip *would do* (the target orientation), not the current state.

---

## Behaviour spec

- The active (frontmost focused) window must be tracked in the slot tree; no-op otherwise.
- The window's **direct parent container** is flipped:
  - If the active window is a direct child of `RootSlot`, flip `root.orientation`.
  - If the active window is a child of a `HorizontalSlot`, replace that node with an equivalent `VerticalSlot`.
  - If the active window is a child of a `VerticalSlot`, replace that node with an equivalent `HorizontalSlot`.
- After flipping, recompute sizes and reapply layout.
- The menu button title reads "Change to vertical" when the current parent is horizontal, and "Change to horizontal" when the current parent is vertical. If no tracked window is active, fall back to "Flip Orientation" (disabled or greyed via `.disabled(true)`).

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/SlotTreeService.swift` | Modify — add two methods |
| `UnnamedWindowManager/Services/SnapService.swift` | Modify — add flip method |
| `UnnamedWindowManager/System/OrientFlipHandler.swift` | **New file** — static handler |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add dynamic menu button |

---

## Implementation Steps

### 1. Add tree-query helpers to `SlotTreeService`

Add two public methods after the existing `// MARK: - Structural mutations` section.

**`findParentOrientation`** — walks the tree to find the container that directly holds the window leaf. If the window is a root-level child, returns `root.orientation`. Returns `nil` if the window is not in the tree.

```swift
func findParentOrientation(of key: WindowSlot, in root: RootSlot) -> Orientation? {
    // Root-level direct child?
    if root.children.contains(where: {
        if case .window(let w) = $0 { return w == key }; return false
    }) { return root.orientation }
    // Recurse into containers
    for child in root.children {
        if let o = findParentOrientation(of: key, in: child) { return o }
    }
    return nil
}
```

Private recursive helper that searches inside a `Slot`:

```swift
private func findParentOrientation(of key: WindowSlot, in slot: Slot) -> Orientation? {
    switch slot {
    case .window: return nil
    case .horizontal(let h):
        if h.children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) { return .horizontal }
        for child in h.children { if let o = findParentOrientation(of: key, in: child) { return o } }
        return nil
    case .vertical(let v):
        if v.children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) { return .vertical }
        for child in v.children { if let o = findParentOrientation(of: key, in: child) { return o } }
        return nil
    }
}
```

**`flipParentOrientation`** — mutates the tree node in place.

```swift
func flipParentOrientation(of key: WindowSlot, in root: inout RootSlot) {
    // Root-level direct child → flip root orientation
    if root.children.contains(where: {
        if case .window(let w) = $0 { return w == key }; return false
    }) {
        root.orientation = root.orientation == .horizontal ? .vertical : .horizontal
        return
    }
    for i in root.children.indices {
        if flipParentOrientation(of: key, in: &root.children[i]) { return }
    }
}
```

Private recursive helper:

```swift
@discardableResult
private func flipParentOrientation(of key: WindowSlot, in slot: inout Slot) -> Bool {
    switch slot {
    case .window: return false
    case .horizontal(var h):
        if h.children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) {
            // Flip to vertical
            slot = .vertical(VerticalSlot(id: h.id, parentId: h.parentId,
                                          width: h.width, height: h.height,
                                          children: h.children, gaps: h.gaps,
                                          fraction: h.fraction))
            return true
        }
        for i in h.children.indices {
            if flipParentOrientation(of: key, in: &h.children[i]) {
                slot = .horizontal(h); return true
            }
        }
        return false
    case .vertical(var v):
        if v.children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) {
            // Flip to horizontal
            slot = .horizontal(HorizontalSlot(id: v.id, parentId: v.parentId,
                                              width: v.width, height: v.height,
                                              children: v.children, gaps: v.gaps,
                                              fraction: v.fraction))
            return true
        }
        for i in v.children.indices {
            if flipParentOrientation(of: key, in: &v.children[i]) {
                slot = .vertical(v); return true
            }
        }
        return false
    }
}
```

### 2. Add `flipParentOrientation` to `SnapService`

```swift
func flipParentOrientation(_ key: WindowSlot, screen: NSScreen) {
    store.queue.sync(flags: .barrier) {
        tree.flipParentOrientation(of: key, in: &store.root)
        position.recomputeSizes(&store.root,
                                width: screen.visibleFrame.width  - Config.gap * 2,
                                height: screen.visibleFrame.height - Config.gap * 2)
    }
}
```

### 3. Create `OrientFlipHandler.swift`

Follows the same pattern as `SnapHandler` and `OrganizeHandler` — a namespace struct with static methods. Uses `windowSlot(for:pid:)` from `AXHelpers.swift`.

```swift
struct OrientFlipHandler {

    /// Returns the orientation of the direct parent container of the active window,
    /// or nil if the active window is not tracked.
    static func parentOrientation() -> Orientation? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success else { return nil }
        let axWindow = ref as! AXUIElement
        let key = windowSlot(for: axWindow, pid: pid)
        let store = SharedRootStore.shared
        return store.queue.sync { SlotTreeService().findParentOrientation(of: key, in: store.root) }
    }

    /// Flips the orientation of the active window's parent container and reapplies layout.
    /// No-op if the active window is not tracked.
    static func flipOrientation() {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success else { return }
        let axWindow = ref as! AXUIElement
        let key = windowSlot(for: axWindow, pid: pid)
        guard SnapService.shared.isTracked(key),
              let screen = NSScreen.main else { return }
        SnapService.shared.flipParentOrientation(key, screen: screen)
        ReapplyHandler.reapplyAll()
    }
}
```

### 4. Update `UnnamedWindowManagerApp.swift`

Add an `@Observable` class `MenuState` and `@State` instance to drive the dynamic label. Read the orientation when the menu content appears.

```swift
@Observable
final class MenuState {
    var parentOrientation: Orientation? = nil

    func refresh() {
        parentOrientation = OrientFlipHandler.parentOrientation()
    }
}
```

In the `@main` struct body:

```swift
@State private var menuState = MenuState()

var body: some Scene {
    MenuBarExtra("Window Manager", systemImage: "rectangle.split.2x1") {
        Button("Snap")     { SnapHandler.snap()        }
        Button("Unsnap")   { UnsnapHandler.unsnap()    }
        Button("Organize") { OrganizeHandler.organize() }
        Divider()
        let orientLabel: String = {
            switch menuState.parentOrientation {
            case .horizontal: return "Change to vertical"
            case .vertical:   return "Change to horizontal"
            case nil:         return "Flip Orientation"
            }
        }()
        Button(orientLabel) {
            OrientFlipHandler.flipOrientation()
            menuState.refresh()
        }
        .disabled(menuState.parentOrientation == nil)
        .onAppear { menuState.refresh() }
        Divider()
        Button("Debug") { WindowLister.logSlotTree() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
    .menuBarExtraStyle(.menu)
}
```

---

## Key Technical Notes

- `HorizontalSlot` and `VerticalSlot` have identical stored properties — the flip is a pure structural swap with no data loss.
- Flipping `root.orientation` affects how `PositionService.recomputeSizes` distributes space among root-level children; the recompute call after the flip is mandatory.
- `@Observable` (Swift 5.9 / macOS 14+) is safe here because the project targets macOS 26.2.
- `menuState.refresh()` is called on `onAppear` so the label is correct the moment the menu opens. It is also called after a successful flip so the label updates immediately if the user clicks again without closing the menu.
- The `@discardableResult` on the private `flipParentOrientation` helper suppresses the Swift warning when called from the `root.children.indices` loop path that doesn't use the return value.
- `isTracked` guard in `flipOrientation()` prevents a no-op flip from triggering a full layout reapply for an untracked window.

---

## Verification

1. Snap two windows side by side → they sit in a `HorizontalSlot` → menu shows "Change to vertical".
2. Click "Change to vertical" → windows stack vertically, menu now shows "Change to horizontal".
3. Click "Change to horizontal" → windows return side by side.
4. With a single window snapped (root-level child), label reads "Change to vertical" (root is horizontal by default) → click → window spans full width vertically → click again → back to horizontal.
5. With no tracked window focused → button label is "Flip Orientation" and is disabled.
6. Snap three windows (root has two children, one of which is a nested container) → focus a window inside the nested container → flip → only the nested container's orientation changes, not root.
