import AppKit
import ApplicationServices

// Routes a newly focused untracked window into the active layout when auto mode is enabled.
struct AutoModeHandler {

    /// Called when window focus changes. Polls until the focused window attribute and
    /// its CGWindowID are both available, then snaps it into the active layout.
    static func handleFocusChange() {
        Logger.shared.log("autoMode: handleFocusChange triggered")
        guard AutoModeService.shared.isEnabled else {
            Logger.shared.log("autoMode: skipped — auto mode disabled")
            return
        }
        guard AXIsProcessTrusted() else {
            Logger.shared.log("autoMode: skipped — AX not trusted")
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            Logger.shared.log("autoMode: skipped — no frontmost app")
            return
        }
        let pid = frontApp.processIdentifier
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard pid != ownPID else {
            Logger.shared.log("autoMode: skipped — own process")
            return
        }

        Logger.shared.log("autoMode: frontmost app pid=\(pid) name=\(frontApp.localizedName ?? "?")")
        pollForWindow(pid: pid, attempts: 0)
    }

    private static let maxReadyAttempts = 10

    /// Polls every 100 ms until the focused window attribute is readable and has a
    /// stable CGWindowID, then snaps it. Shows a notification if it gives up.
    private static func pollForWindow(pid: pid_t, attempts: Int) {
        guard attempts < maxReadyAttempts else {
            Logger.shared.log("autoMode: giving up after \(maxReadyAttempts) attempts")
            NotificationService.shared.post(title: "Auto Mode", body: "Window did not initialize in time")
            return
        }

        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else {
            Logger.shared.log("autoMode: attempt \(attempts + 1) — focused window not readable yet, retrying")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollForWindow(pid: pid, attempts: attempts + 1)
            }
            return
        }

        let axWindow = ref as! AXUIElement
        guard windowID(of: axWindow) != nil else {
            Logger.shared.log("autoMode: attempt \(attempts + 1) — no CGWindowID yet, retrying")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollForWindow(pid: pid, attempts: attempts + 1)
            }
            return
        }

        Logger.shared.log("autoMode: window ready after \(attempts + 1) attempt(s), proceeding to snap")
        snap(axWindow, pid: pid)
    }

    private static func snap(_ window: AXUIElement, pid: pid_t) {
        let key = windowSlot(for: window, pid: pid)
        Logger.shared.log("autoMode: snap pid=\(pid) hash=\(key.windowHash)")

        guard !TilingRootStore.shared.isTracked(key) else {
            Logger.shared.log("autoMode: skipped — already tracked in tiling")
            return
        }
        guard !ScrollingRootStore.shared.isTracked(key) else {
            Logger.shared.log("autoMode: skipped — already tracked in scrolling")
            return
        }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true {
            Logger.shared.log("autoMode: skipped — window is minimized")
            return
        }
        if let size = readSize(of: window), size.width < 100 || size.height < 100 {
            Logger.shared.log("autoMode: skipped — window too small (\(size))")
            return
        }

        if TilingRootStore.shared.snapshotVisibleRoot() != nil {
            Logger.shared.log("autoMode: tiling snap")
            TileHandler.tileLeft(window: window, pid: pid)
        } else if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
            Logger.shared.log("autoMode: scrolling snap")
            ScrollHandler.scrollWindow(window, pid: pid)
        } else {
            Logger.shared.log("autoMode: skipped — no active root")
            return
        }

        guard let screen = NSScreen.main else { return }
        let allKeys = Set(ResizeObserver.shared.keysByHash.values)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            PostResizeValidator.checkAndFixRefusals(windows: allKeys, screen: screen)
        }
    }
}
