import AppKit

// Checks tiled windows after a resize and corrects any that refused the target size.
enum PostResizeValidator {

    @discardableResult
    static func checkAndFixRefusals(windows: Set<WindowSlot>, screen: NSScreen) -> Set<WindowSlot> {
        struct Refusal {
            let key: WindowSlot
            let actual: CGSize
        }

        let observer = ResizeObserver.shared
        var refusals: [Refusal] = []
        let leaves = TilingRootStore.shared.leavesInVisibleRoot()
                    + ScrollingRootStore.shared.leavesInVisibleScrollingRoot()

        for leaf in leaves {
            guard case .window(let w) = leaf, windows.contains(w) else { continue }
            guard let axEl = observer.elements[w], let actual = readSize(of: axEl) else { continue }

            let gap     = w.gaps ? Config.innerGap * 2 : 0
            let targetW = w.size.width  - gap
            let targetH = w.size.height - gap

            guard abs(actual.width - targetW) > 2 || abs(actual.height - targetH) > 2 else { continue }

            refusals.append(Refusal(key: w, actual: actual))
        }

        guard !refusals.isEmpty else {
            return []
        }

        let allTracked = Set(leaves.compactMap { leaf -> WindowSlot? in
            if case .window(let w) = leaf { return w }
            return nil
        })
        observer.reapplying.formUnion(allTracked)

        for r in refusals {
            if ScrollingRootStore.shared.isTracked(r.key) {
                // For scrolling windows, TilingEditService is a no-op.
                // Clear the cache so applyLayout retries the AX call.
                ScrollingLayoutService.shared.clearCache(for: r.key)
            } else {
                TilingEditService.shared.resize(key: r.key, actualSize: r.actual, screen: screen)
            }
        }
        LayoutService.shared.applyLayout(screen: screen)

        var lastSizes: [WindowSlot: CGSize] = [:]
        SettlePoller.poll(condition: {
            var stable = true
            for key in allTracked {
                guard let axEl = observer.elements[key],
                      let size = readSize(of: axEl) else { continue }
                if lastSizes[key] != size { stable = false }
                lastSizes[key] = size
            }
            return stable && !lastSizes.isEmpty
        }) { _ in
            observer.reapplying.subtract(allTracked)
        }

        return Set(refusals.map(\.key))
    }
}
