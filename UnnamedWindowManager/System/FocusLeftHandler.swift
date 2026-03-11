// Entry point for the focus-left shortcut.
struct FocusLeftHandler {
    static func focus() {
        let scrollingRoot = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        Logger.shared.log("focus-left: scrollingRoot=\(scrollingRoot != nil ? "found left=\(scrollingRoot!.left != nil) right=\(scrollingRoot!.right != nil)" : "nil")")
        if scrollingRoot != nil {
            ScrollingFocusService.scrollLeft()
        } else {
            FocusDirectionService.focus(.left)
        }
    }
}
