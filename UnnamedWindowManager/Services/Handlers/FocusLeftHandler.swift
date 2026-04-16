import AppKit
import ApplicationServices

// Entry point for the focus-left shortcut.
struct FocusLeftHandler {
    static func focus() {
        guard let screen = NSScreen.main else { return }
        guard let before = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() else {
            FocusDirectionService.focus(.left)
            return
        }
        guard let newCenter = ScrollingRootStore.shared.scrollLeft(screen: screen) else { return }
        guard let after = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() else { return }
        let origin = screenLayoutOrigin(screen)
        let elements = WindowTracker.shared.elements
        ScrollingAnimationService.shared.animateScroll(before: before, after: after, origin: origin, elements: elements)
        guard let ax = WindowTracker.shared.elements[newCenter] else { return }
        NSRunningApplication(processIdentifier: newCenter.pid)?.activate()
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }
}
