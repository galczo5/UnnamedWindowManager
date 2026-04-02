import AppKit
import ApplicationServices

// Routes a newly focused untracked window into the active layout when auto mode is enabled.
struct AutoModeHandler {

    /// Called when window focus changes. If auto mode is on and the focused window is not yet
    /// tracked, snaps it into the active tiling or scrolling root.
    /// `retryCount` limits retries when the new window hasn't received its CGWindowID yet.
    static func handleFocusChange(retryCount: Int = 0) {
        guard AutoModeService.shared.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard pid != ownPID else { return }

        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return }
        let axWindow = ref as! AXUIElement

        // GPU-rendered apps (Ghostty, Alacritty) may not have a CGWindowID immediately after focus.
        // Retry until it's available so windowSlot produces a stable hash.
        guard windowID(of: axWindow) != nil else {
            guard retryCount < 4 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                handleFocusChange(retryCount: retryCount + 1)
            }
            return
        }

        let key = windowSlot(for: axWindow, pid: pid)
        guard !TilingRootStore.shared.isTracked(key) else { return }
        guard !ScrollingRootStore.shared.isTracked(key) else { return }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true { return }
        // Match tileLeft's pattern: only skip if size IS known and too small.
        if let size = readSize(of: axWindow), size.width < 100 || size.height < 100 { return }

        if TilingRootStore.shared.snapshotVisibleRoot() != nil {
            TileHandler.tileLeft(window: axWindow, pid: pid)
        } else if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
            ScrollHandler.scrollWindow(axWindow, pid: pid)
        } else {
            return
        }

        guard let screen = NSScreen.main else { return }
        let allKeys = Set(ResizeObserver.shared.keysByHash.values)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            PostResizeValidator.checkAndFixRefusals(windows: allKeys, screen: screen)
        }
    }
}
