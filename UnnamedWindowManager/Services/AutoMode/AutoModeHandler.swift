import AppKit
import ApplicationServices

// Routes a newly focused untracked window into the active layout when auto mode is enabled.
struct AutoModeHandler {

    /// Called when window focus changes. Polls until the focused window attribute and
    /// its CGWindowID are both available, then snaps it into the active layout.
    static func handleFocusChange() {
        guard AutoModeService.shared.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard pid != ownPID else { return }

        pollForWindow(pid: pid, attempts: 0)
    }

    private static let maxReadyAttempts = 10

    /// Polls every 100 ms until the focused window attribute is readable and has a
    /// stable CGWindowID, then snaps it. Shows a notification if it gives up.
    private static func pollForWindow(pid: pid_t, attempts: Int) {
        guard attempts < maxReadyAttempts else {
            NotificationService.shared.post(title: "Auto Mode", body: "Window did not initialize in time")
            return
        }

        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollForWindow(pid: pid, attempts: attempts + 1)
            }
            return
        }

        let axWindow = ref as! AXUIElement
        guard windowID(of: axWindow) != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollForWindow(pid: pid, attempts: attempts + 1)
            }
            return
        }

        snap(axWindow, pid: pid)
    }

    private static func snap(_ window: AXUIElement, pid: pid_t) {
        let key = windowSlot(for: window, pid: pid)

        guard !TilingRootStore.shared.isTracked(key) else { return }
        guard !ScrollingRootStore.shared.isTracked(key) else { return }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true {
            return
        }
        if let size = readSize(of: window), size.width < 100 || size.height < 100 { return }

        let tilingRoot = TilingRootStore.shared.snapshotVisibleRoot()
        let scrollingRoot = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()

        if tilingRoot != nil && scrollingRoot != nil {
            switch SharedRootStore.shared.activeRootType {
            case .scrolling:
                ScrollHandler.scrollWindow(window, pid: pid)
            default:
                TileHandler.tileLeft(window: window, pid: pid)
            }
        } else if tilingRoot != nil {
            TileHandler.tileLeft(window: window, pid: pid)
        } else if scrollingRoot != nil {
            ScrollHandler.scrollWindow(window, pid: pid)
        } else {
            return
        }

        guard let screen = NSScreen.main else { return }
        let allKeys = Set(WindowTracker.shared.keysByHash.values)
        let observer = WindowTracker.shared
        SettlePoller.poll(condition: {
            allKeys.allSatisfy { key in
                guard let axEl = observer.elements[key],
                      let actual = readSize(of: axEl) else { return false }
                let gap = key.gaps ? Config.innerGap * 2 : 0
                return abs(actual.width  - (key.size.width  - gap)) <= 2
                    && abs(actual.height - (key.size.height - gap)) <= 2
            }
        }) { _ in
            PostResizeValidator.checkAndFixRefusals(windows: allKeys, screen: screen)
        }
    }
}
