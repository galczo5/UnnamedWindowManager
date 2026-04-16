import AppKit
import ApplicationServices

// Entry point for tiling the focused window into the layout.
struct TileHandler {

    /// Tiles the frontmost focused window into the layout.
    /// Prompts for AX trust if not yet granted. No-op if the window is already tracked.
    static func tile() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement

        guard let screen = NSScreen.main else { return }
        let key = windowSlot(for: axWindow, pid: pid)

        // If a managed window from the same PID is no longer on screen, it became an
        // inactive tab. Swap its slot identity to the focused window instead of adding a new slot.
        let managedSiblings = WindowTracker.shared.keysByPid[pid] ?? []
        let freshTabGroup = TabRecognizer.tabSiblingHashes(of: key.windowHash, pid: pid)
        for siblingKey in managedSiblings {
            if siblingKey.isSameTabGroup(hash: key.windowHash) || freshTabGroup.contains(siblingKey.windowHash) {
                WindowEventRouter.shared.swapTab(oldKey: siblingKey,
                                              newWindow: axWindow, newHash: key.windowHash)
                ReapplyHandler.reapplyAll()
                return
            }
        }

        var mutableKey = key
        mutableKey.preTileOrigin = readOrigin(of: axWindow)
        mutableKey.preTileSize = readSize(of: axWindow)
        let tabSiblings = TabRecognizer.tabSiblingHashes(of: mutableKey.windowHash, pid: pid)
        if !tabSiblings.isEmpty {
            mutableKey.isTabbed = true
            mutableKey.tabHashes = tabSiblings
        }
        SharedRootStore.shared.setActiveRootType(.tiling)
        TilingService.shared.snap(mutableKey, screen: screen)
        WindowEventRouter.shared.observe(window: axWindow, pid: pid, key: mutableKey)
        ReapplyHandler.reapplyAll()
    }

    /// Tiles the frontmost window if it is not tiled, or untiles it if it is.
    static func tileToggle() {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let key = windowSlot(for: focusedWindow as! AXUIElement, pid: pid)
        if TilingRootStore.shared.isTracked(key) {
            UntileHandler.untile()
        } else {
            tile()
        }
    }

    /// Tiles `window` into the layout as a new leaf.
    /// Skips windows that are already tracked, minimised, or smaller than 100×100 pts.
    static func tileLeft(window: AXUIElement, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard let screen = NSScreen.main else { return }

        var key = windowSlot(for: window, pid: pid)
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true { return }
        if let sz = readSize(of: window), sz.width < 100 || sz.height < 100 { return }

        key.preTileOrigin = readOrigin(of: window)
        key.preTileSize = readSize(of: window)
        let tabSiblings = TabRecognizer.tabSiblingHashes(of: key.windowHash, pid: pid)
        if !tabSiblings.isEmpty {
            key.isTabbed = true
            key.tabHashes = tabSiblings
        }
        TilingService.shared.snap(key, screen: screen)
        WindowEventRouter.shared.observe(window: window, pid: pid, key: key)
        ReapplyHandler.reapplyAll()
    }
}
