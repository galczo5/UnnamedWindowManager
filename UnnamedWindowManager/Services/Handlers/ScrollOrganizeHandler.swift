import AppKit
import ApplicationServices

// Scrolls all visible on-screen windows into the scrolling root in one batch, ordered by position.
struct ScrollOrganizeHandler {

    /// Scrolls all visible on-screen windows into the scrolling root, ordered left-to-right by x-origin.
    /// Skips windows already tracked, minimised, owned by this process, or smaller than 100×100 pts.
    /// No-op if a tiling root is active.
    static func organizeScrolling() {
        guard AXIsProcessTrusted() else { return }
        guard TilingRootStore.shared.snapshotVisibleRoot() == nil else { return }
        guard let screen = NSScreen.main else { return }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        guard let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var pidToWindowIDs: [pid_t: Set<CGWindowID>] = [:]
        for info in cgList {
            guard let layer  = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid    = info[kCGWindowOwnerPID as String] as? Int,
                  let wid    = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 100, h > 100,
                  pid_t(pid) != ownPID
            else { continue }
            pidToWindowIDs[pid_t(pid), default: []].insert(wid)
        }

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

        let sorted = candidates.sorted(by: { $0.originX < $1.originX })
        var rootExists = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil
        for (i, item) in sorted.enumerated() {
            let delay = Double(i) * 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let screen = NSScreen.main else { return }
                var key = windowSlot(for: item.window, pid: item.pid)
                key.preTileOrigin = readOrigin(of: item.window)
                key.preTileSize   = readSize(of: item.window)
                if rootExists {
                    ScrollingRootStore.shared.addWindow(key, screen: screen)
                } else {
                    ScrollingRootStore.shared.createScrollingRoot(key: key, screen: screen)
                    rootExists = true
                }
                ResizeObserver.shared.observe(window: item.window, pid: item.pid, key: key)
                ReapplyHandler.reapplyAll()
            }
        }
        let count = sorted.count
        let notifyDelay = count > 0 ? Double(count - 1) * 0.1 + 0.5 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + notifyDelay) {
            if count == 0 {
                NotificationService.shared.post(title: "Scroll All", body: "No windows to organize")
            } else {
                let noun = count == 1 ? "window" : "windows"
                NotificationService.shared.post(title: "Scroll All", body: "\(count) \(noun) organized")
            }
        }
    }
}
