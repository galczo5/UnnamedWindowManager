import AppKit

// Polls for mouse-up then reapplies tile position, handling resize, move, and scrolling reapply.
final class DragReapplyScheduler {
    private weak var observer: ResizeObserver?
    private var pending: [WindowSlot: DispatchWorkItem] = [:]
    let overlay = SwapOverlay()
    private var lastDropTarget: DropTarget?
    private var dropTargetEnteredAt: Date?

    init(observer: ResizeObserver) {
        self.observer = observer
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
            guard let self, let observer = self.observer else { return }
            self.pending.removeValue(forKey: key)

            if NSEvent.pressedMouseButtons != 0 {
                self.schedule(key: key, isResize: isResize, isScrolling: isScrolling)
                return
            }

            self.overlay.hide()

            guard !observer.reapplying.contains(key),
                  observer.elements[key] != nil else { return }

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
        guard let observer else { return }
        observer.reapplying.insert(key)
        if let screen = NSScreen.main {
            let isCenterResize = isResize && ScrollingRootStore.shared.isCenterWindow(key)
            if isCenterResize,
               let axElement = observer.elements[key],
               let actualSize = readSize(of: axElement) {
                ScrollingResizeService().applyResize(
                    centerKey: key, actualWidth: actualSize.width, screen: screen)
            }
            ScrollingLayoutService.shared.clearCache(for: key)
            LayoutService.shared.applyLayout(screen: screen, scrollingSidesPositionOnly: isCenterResize)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let windows = Set(ScrollingRootStore.shared.leavesInVisibleScrollingRoot()
                    .compactMap { (slot: Slot) -> WindowSlot? in
                        guard case .window(let w) = slot else { return nil }
                        return w
                    })
                PostResizeValidator.checkAndFixRefusals(windows: windows, screen: screen)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak observer] in
            observer?.reapplying.remove(key)
        }
    }

    private func reapplyResize(key: WindowSlot) {
        guard let observer,
              let screen = NSScreen.main,
              let axElement = observer.elements[key],
              let actualSize = readSize(of: axElement) else { return }

        TilingEditService.shared.resize(key: key, actualSize: actualSize, screen: screen)
        ReapplyHandler.reapplyAll()
    }

    private func reapplyMove(key: WindowSlot) {
        guard let observer else { return }
        let hoverStart = dropTargetEnteredAt
        lastDropTarget = nil
        dropTargetEnteredAt = nil

        let hoverDuration = hoverStart.map { Date().timeIntervalSince($0) } ?? 0
        let dropAllowed = hoverDuration >= Config.dropZoneHoverDelay
        if dropAllowed, let drop = ReapplyHandler.findDropTarget(forKey: key) {
            if drop.zone == .center {
                TilingEditService.shared.swap(key, drop.window)
            } else if let screen = NSScreen.main {
                TilingEditService.shared.insertAdjacent(dragged: key, target: drop.window,
                                                  zone: drop.zone, screen: screen)
            }
            ReapplyHandler.reapplyAll()
        } else {
            guard let storedElement = observer.elements[key] else { return }
            observer.reapplying.insert(key)
            ReapplyHandler.reapply(window: storedElement, key: key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak observer] in
                observer?.reapplying.remove(key)
            }
        }
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
