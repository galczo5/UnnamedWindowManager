import AppKit
import ApplicationServices

// Snaps all visible on-screen windows into the layout in one batch, ordered by position.
struct OrganizeHandler {

    /// Snaps all visible on-screen windows into the layout, ordered left-to-right by their x-origin.
    /// Skips windows that are already tracked, minimised, owned by this process, or smaller than 100×100 pts.
    static func organize() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }
        guard let screen = NSScreen.main else { return }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        guard let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        // Build a map of pid → window IDs for normal-layer windows that meet the size threshold.
        var pidToWindowIDs: [pid_t: Set<CGWindowID>] = [:]
        for info in cgList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 100, h > 100,
                  pid_t(pid) != ownPID
            else { continue }
            pidToWindowIDs[pid_t(pid), default: []].insert(wid)
        }

        // Collect AX window handles alongside their screen x-origin for sorting.
        var candidates: [(window: AXUIElement, pid: pid_t, originX: CGFloat)] = []
        for (pid, wids) in pidToWindowIDs {
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }
            for axWindow in axWindows {
                guard let wid = windowID(of: axWindow), wids.contains(wid) else { continue }
                var minRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   (minRef as? Bool) == true { continue }
                let originX = readOrigin(of: axWindow)?.x ?? 0
                candidates.append((window: axWindow, pid: pid, originX: originX))
            }
        }

        // Snap candidates in left-to-right order, then reapply layout once.
        var snappedKeys: Set<WindowSlot> = []
        for item in candidates.sorted(by: { $0.originX < $1.originX }) {
            let key = windowSlot(for: item.window, pid: item.pid)
            SnapService.shared.snap(key, screen: screen)
            ResizeObserver.shared.observe(window: item.window, pid: item.pid, key: key)
            snappedKeys.insert(key)
        }
        ReapplyHandler.reapplyAll()
    }
}
