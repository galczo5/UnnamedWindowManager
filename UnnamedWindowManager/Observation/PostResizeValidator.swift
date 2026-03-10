import AppKit

// Checks tiled windows after a resize and corrects any that refused the target size.
enum PostResizeValidator {

    static func checkAndFixRefusals(windows: Set<WindowSlot>, screen: NSScreen) {
        struct Refusal {
            let key: WindowSlot
            let actual: CGSize
            let appName: String
        }

        let observer = ResizeObserver.shared
        var refusals: [Refusal] = []
        let leaves = TileService.shared.leavesInVisibleRoot()

        for leaf in leaves {
            guard case .window(let w) = leaf, windows.contains(w) else { continue }
            guard let axEl = observer.elements[w], let actual = readSize(of: axEl) else { continue }

            let gap     = w.gaps ? Config.innerGap * 2 : 0
            let targetW = w.width  - gap
            let targetH = w.height - gap

            guard abs(actual.width - targetW) > 2 || abs(actual.height - targetH) > 2 else { continue }

            let appName = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "Unknown"
            refusals.append(Refusal(key: w, actual: actual, appName: appName))
        }

        guard !refusals.isEmpty else { return }

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

        for r in refusals {
            NotificationService.shared.post(
                title: "Window refused to resize",
                body: "\(r.appName) could not be resized to fit its slot."
            )
        }
    }
}
