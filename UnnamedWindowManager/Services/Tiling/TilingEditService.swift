import AppKit

/// Structural modifications to existing tiling layouts: resize, swap, flip, insert, and recompute.
final class TilingEditService {
    static let shared = TilingEditService()
    private init() {}

    private let store     = SharedRootStore.shared
    private let rootStore = TilingRootStore.shared

    func resize(key: WindowSlot, actualSize: CGSize, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.rootIDSync(containing: key),
                  case .tiling(var root) = store.roots[id] else { return }
            root.applyResize(key: key, actualSize: actualSize)
            let area = screenTilingArea(screen)
            root.recomputeSizes(width: area.width, height: area.height)
            store.roots[id] = .tiling(root)
        }
    }

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        guard keyA != keyB else { return }
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.rootIDSync(containing: keyA),
                  case .tiling(var root) = store.roots[id],
                  root.isTracked(keyB) else { return }
            let resolvedA: WindowSlot
            if let s = root.findLeaf(keyA), case .window(let w) = s { resolvedA = w } else { resolvedA = keyA }
            let resolvedB: WindowSlot
            if let s = root.findLeaf(keyB), case .window(let w) = s { resolvedB = w } else { resolvedB = keyB }
            root.swap(resolvedA, resolvedB)
            store.roots[id] = .tiling(root)
        }
    }

    func recomputeVisibleRootSizes(screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.visibleRootID(),
                  case .tiling(var root) = store.roots[id] else { return }
            let area = screenTilingArea(screen)
            root.recomputeSizes(width: area.width, height: area.height)
            store.roots[id] = .tiling(root)
        }
    }

    func flipParentOrientation(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.rootIDSync(containing: key),
                  case .tiling(var root) = store.roots[id] else { return }
            root.flipParentOrientation(of: key)
            let area = screenTilingArea(screen)
            root.recomputeSizes(width: area.width, height: area.height)
            store.roots[id] = .tiling(root)
        }
    }

    func insertAdjacent(dragged: WindowSlot, target: WindowSlot,
                        zone: DropZone, screen: NSScreen) {
        guard dragged != target else { return }
        store.queue.sync(flags: .barrier) {
            guard let draggedRootID = rootStore.rootIDSync(containing: dragged),
                  let targetRootID  = rootStore.rootIDSync(containing: target),
                  case .tiling(var draggedRoot) = store.roots[draggedRootID],
                  case .tiling(var targetRoot)  = store.roots[targetRootID],
                  let draggedSlot = draggedRoot.findLeaf(dragged),
                  case .window(let draggedWindow) = draggedSlot else { return }

            if draggedRootID == targetRootID {
                targetRoot.removeLeaf(dragged)
            } else {
                draggedRoot.removeLeaf(dragged)
                if draggedRoot.children.isEmpty {
                    store.removeRoot(id: draggedRootID)
                } else {
                    store.roots[draggedRootID] = .tiling(draggedRoot)
                }
            }

            let newLeaf = Slot.window(WindowSlot(
                pid: draggedWindow.pid, windowHash: draggedWindow.windowHash,
                id: UUID(), parentId: targetRoot.id,
                order: draggedWindow.order, size: .zero, gaps: true,
                preTileOrigin: draggedWindow.preTileOrigin, preTileSize: draggedWindow.preTileSize
            ))
            targetRoot.insertAdjacent(newLeaf, adjacentTo: target, zone: zone)
            let area = screenTilingArea(screen)
            targetRoot.recomputeSizes(width: area.width, height: area.height)
            store.roots[targetRootID] = .tiling(targetRoot)
        }
    }
}
