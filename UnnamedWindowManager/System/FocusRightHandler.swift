// Entry point for the focus-right shortcut.
struct FocusRightHandler {
    static func focus() {
        let scrollingRoot = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        Logger.shared.log("focus-right: scrollingRoot=\(scrollingRoot != nil ? "found left=\(scrollingRoot!.left != nil) right=\(scrollingRoot!.right != nil)" : "nil")")
        if scrollingRoot != nil {
            ScrollingFocusService.scrollRight()
        } else {
            FocusDirectionService.focus(.right)
        }
    }
}
