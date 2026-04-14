import AppKit

// Polls for mouse-up then reapplies tile position, handling resize, move, and scrolling reapply.
final class TilingDragHandler {
    private weak var tracker: WindowTracker?
    private var pending: [WindowSlot: DispatchWorkItem] = [:]
    let overlay = TilingDropOverlay()
    private var lastDropTarget: DropTarget?
    private var dropTargetEnteredAt: Date?
    private var postMoveCheck: DispatchWorkItem?

    init(tracker: WindowTracker) {
        self.tracker = tracker
    }

    func cancel(key: WindowSlot) {
        pending[key]?.cancel()
        pending.removeValue(forKey: key)
    }

    func updateDragOverlay(forKey key: WindowSlot, element: AXUIElement,
                           elements: [WindowSlot: AXUIElement]) {
        let drop = ReapplyHandler.findDropTarget(forKey: key)
        updateTrackedDropTarget(drop)
        overlay.update(dropTarget: drop, draggedWindow: element, elements: elements)
    }

    func schedule(key: WindowSlot, isResize: Bool, isScrolling: Bool) {
        pending[key]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, let tracker = self.tracker else { return }
            self.pending.removeValue(forKey: key)

            if NSEvent.pressedMouseButtons != 0 {
                self.schedule(key: key, isResize: isResize, isScrolling: isScrolling)
                return
            }

            self.overlay.hide()

            guard !tracker.reapplying.contains(key),
                  tracker.elements[key] != nil else { return }

            if isScrolling {
                self.reapplyScrolling(key: key, isResize: isResize)
            } else if isResize {
                self.reapplyResize(key: key)
            } else {
                self.reapplyMove(key: key)
            }
        }

        pending[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    // MARK: - Private

    private func reapplyScrolling(key: WindowSlot, isResize: Bool) {
        guard let tracker, let screen = NSScreen.main else { return }
        let isCenterResize = isResize && ScrollingRootStore.shared.isCenterWindow(key)
        if isCenterResize, let axElement = tracker.elements[key] {
            // Prefer the frame captured before any in-flight reapply so a fast gesture
            // during an animation reads the user-visible width, not an interpolated one.
            let width = WindowTracker.shared.preReapplyFrame(for: key)?.size.width
                ?? readSize(of: axElement)?.width
            if let w = width {
                let screenWidth = screenTilingArea(screen).width
                ScrollingRootStore.shared.updateCenterFraction(
                    for: key, proposedWidth: w, screenWidth: screenWidth, screen: screen)
            }
        }
        ReapplyHandler.reapplyAll(scrollingSidesPositionOnly: isCenterResize)
    }

    private func reapplyResize(key: WindowSlot) {
        guard let tracker,
              let screen = NSScreen.main,
              let axElement = tracker.elements[key] else { return }

        // Use the pre-reapply size when a generation is in flight; otherwise AX.
        guard let actualSize = WindowTracker.shared.preReapplyFrame(for: key)?.size
                ?? readSize(of: axElement) else { return }

        TilingService.shared.resize(key: key, actualSize: actualSize, screen: screen)
        ReapplyHandler.reapplyAll()
    }

    private func reapplyMove(key: WindowSlot) {
        let hoverStart = dropTargetEnteredAt
        lastDropTarget = nil
        dropTargetEnteredAt = nil

        let hoverDuration = hoverStart.map { Date().timeIntervalSince($0) } ?? 0
        let dropAllowed = hoverDuration >= Config.dropZoneHoverDelay
        if dropAllowed, let drop = ReapplyHandler.findDropTarget(forKey: key) {
            if drop.zone == .center {
                TilingService.shared.swap(key, drop.window)
            } else if let screen = NSScreen.main {
                TilingService.shared.insertAdjacent(dragged: key, target: drop.window,
                                                  zone: drop.zone, screen: screen)
            }
        }
        // Snap-back (no drop) and drop branches both re-run the full layout.
        // reapplyAll() owns generation + reapplying + preReapplyFrame state.
        ReapplyHandler.reapplyAll()

        // Mission Control commits a window move after its animation completes (~0.5–1s),
        // after which no AX notification fires. Schedule a delayed reapply so
        // pruneOffScreenWindows can detect the window on its new space and untile it.
        postMoveCheck?.cancel()
        let check = DispatchWorkItem {
            guard NSEvent.pressedMouseButtons == 0 else { return }
            ReapplyHandler.reapplyAll()
        }
        postMoveCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: check)
    }

    private func updateTrackedDropTarget(_ newTarget: DropTarget?) {
        guard let new = newTarget else {
            lastDropTarget = nil
            dropTargetEnteredAt = nil
            return
        }
        if let last = lastDropTarget, last.window == new.window, last.zone == new.zone { return }
        lastDropTarget = new
        dropTargetEnteredAt = Date()
    }
}
