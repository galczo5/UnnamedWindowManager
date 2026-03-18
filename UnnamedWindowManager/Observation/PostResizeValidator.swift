import AppKit

// Checks tiled windows after a resize and corrects any that refused the target size.
enum PostResizeValidator {

    @discardableResult
    static func checkAndFixRefusals(windows: Set<WindowSlot>, screen: NSScreen) -> Set<WindowSlot> {
        Logger.shared.log("checkAndFixRefusals: windows=\(windows.count)")
        struct Refusal {
            let key: WindowSlot
            let actual: CGSize
        }

        let observer = ResizeObserver.shared
        var refusals: [Refusal] = []
        let leaves = TileService.shared.leavesInVisibleRoot()
                    + ScrollingTileService.shared.leavesInVisibleScrollingRoot()

        for leaf in leaves {
            guard case .window(let w) = leaf, windows.contains(w) else { continue }
            guard let axEl = observer.elements[w], let actual = readSize(of: axEl) else { continue }

            let gap     = w.gaps ? Config.innerGap * 2 : 0
            let targetW = w.width  - gap
            let targetH = w.height - gap

            guard abs(actual.width - targetW) > 2 || abs(actual.height - targetH) > 2 else { continue }

            refusals.append(Refusal(key: w, actual: actual))
        }

        guard !refusals.isEmpty else {
            Logger.shared.log("checkAndFixRefusals: no refusals, skipping")
            return []
        }

        let allTracked = Set(leaves.compactMap { leaf -> WindowSlot? in
            if case .window(let w) = leaf { return w }
            return nil
        })
        observer.reapplying.formUnion(allTracked)

        for r in refusals {
            TileService.shared.resize(key: r.key, actualSize: r.actual, screen: screen)
        }
        LayoutService.shared.applyLayout(screen: screen)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            observer.reapplying.subtract(allTracked)
        }

        return Set(refusals.map(\.key))
    }
}
