import AppKit
import ApplicationServices

// Handles focus change effects: window dimming, tab detection, border updates, scroll-to-center.
final class FocusChangeHandler {
    static let shared = FocusChangeHandler()
    private init() {}

    private var retryWorkItem: DispatchWorkItem?

    func handleFocusChange(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref
        else {
            WindowOpacityService.shared.restoreAll()
            FocusedWindowBorderService.shared.hide()
            return
        }
        let axWindow = ref as! AXUIElement

        let wid = windowID(of: axWindow)
        let hash = wid.map(UInt.init)
        let isManaged = hash.flatMap({ WindowTracker.shared.keysByHash[$0] }) != nil

        // Tab switch detection: focused window is unmanaged, but a managed window from the same PID
        // is either off-screen or a known tab sibling of the new window.
        // Invalidate the cache first to avoid stale data from before the tab switch.
        retryWorkItem?.cancel()
        retryWorkItem = nil

        if !isManaged, let hash {
            OnScreenWindowCache.invalidate()
            let onScreen = OnScreenWindowCache.visibleHashes()
            let managedSiblings = WindowTracker.shared.keysByPid[pid] ?? []
            // freshTabGroup uses bounds-matching (the authoritative check) and catches
            // new tabs whose hash was never in the existing slot's tabHashes.
            let freshTabGroup = WindowTabDetector.tabSiblingHashes(of: hash, pid: pid)
            var swapped = false
            for siblingKey in managedSiblings {
                // Skip tab swap if sibling is in a root whose type doesn't match
                // the active root — avoids pulling windows across spaces.
                if let activeType = SharedRootStore.shared.activeRootType {
                    let inTiling = TilingRootStore.shared.rootID(containing: siblingKey) != nil
                    let inScrolling = ScrollingRootStore.shared.scrollingRootInfo(containing: siblingKey) != nil
                    if (inTiling && activeType != .tiling)
                        || (inScrolling && activeType != .scrolling) {
                        continue
                    }
                }
                if siblingKey.isSameTabGroup(hash: hash)
                    || !onScreen.contains(siblingKey.windowHash)
                    || freshTabGroup.contains(siblingKey.windowHash) {
                    WindowEventRouter.shared.swapTab(oldKey: siblingKey, newWindow: axWindow, newHash: hash)
                    ReapplyHandler.reapplyAll()
                    swapped = true
                    break
                }
            }
            // If detection failed but managed siblings exist, the new window's bounds may not
            // have settled in CGWindowList yet. Poll until the hash appears.
            if !swapped, !managedSiblings.isEmpty {
                let work = DispatchWorkItem { [weak self] in
                    SettlePoller.poll(condition: {
                        OnScreenWindowCache.invalidate()
                        return OnScreenWindowCache.visibleHashes().contains(hash)
                    }) { settled in
                        guard settled else { return }
                        self?.handleFocusChange(pid: pid)
                    }
                }
                retryWorkItem = work
                DispatchQueue.main.async(execute: work)
                return
            }
        }

        guard let wid, let key = WindowTracker.shared.keysByHash[UInt(wid)] else {
            WindowOpacityService.shared.restoreAll()
            FocusedWindowBorderService.shared.hide()
            return
        }

        if let info = ScrollingRootStore.shared.scrollingRootInfo(containing: key) {
            if info.centerHash != key.windowHash {
                if let screen = NSScreen.main {
                    let before = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()
                    if let newCenter = ScrollingRootStore.shared.scrollToWindow(key, screen: screen),
                       let after = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() {
                        let zonesChanged = (before?.left != nil, before?.right != nil) != (after.left != nil, after.right != nil)
                        let origin = screenLayoutOrigin(screen)
                        let elements = WindowTracker.shared.elements
                        ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                                                   zonesChanged: zonesChanged, applyCenter: false)
                        ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                                                   applySides: false)
                        if let ax = WindowTracker.shared.elements[newCenter] {
                            NSRunningApplication(processIdentifier: newCenter.pid)?.activate()
                            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                        }
                    }
                }
                if let updated = ScrollingRootStore.shared.scrollingRootInfo(containing: key) {
                    WindowOpacityService.shared.dim(rootID: updated.rootID, focusedHash: updated.centerHash)
                }
            } else {
                WindowOpacityService.shared.dim(rootID: info.rootID, focusedHash: info.centerHash)
            }
            FocusedWindowBorderService.shared.show(windowID: wid, axElement: axWindow)
        } else if let rootID = TilingRootStore.shared.rootID(containing: key) {
            WindowOpacityService.shared.dim(rootID: rootID, focusedHash: key.windowHash)
            FocusedWindowBorderService.shared.show(windowID: wid, axElement: axWindow)
        } else {
            WindowOpacityService.shared.restoreAll()
            FocusedWindowBorderService.shared.hide()
        }
    }
}
