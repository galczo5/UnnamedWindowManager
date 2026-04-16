import AppKit
import ApplicationServices

enum FocusDirection {
    case left, right, up, down
}

// Directional window focus: finds the nearest neighbour via TilingNeighborService and activates it.
struct FocusDirectionService {

    static func focus(_ direction: FocusDirection) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return
        }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success else {
            return
        }
        let axWindow = ref as! AXUIElement
        let currentKey = windowSlot(for: axWindow, pid: pid)

        guard let root = TilingRootStore.shared.snapshotVisibleRoot() else {
            return
        }
        guard let targetKey = TilingNeighborService.findNeighbor(of: currentKey, direction: direction, in: root) else {
            return
        }
        activateWindow(targetKey)
    }

    // MARK: - Private

    private static func activateWindow(_ key: WindowSlot) {
        let elements = WindowTracker.shared.elements
        guard let axElement = elements[key] else { return }
        guard let app = NSRunningApplication(processIdentifier: key.pid) else { return }
        app.activate()
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }
}
