// Entry point for the focus-right shortcut.
struct FocusRightHandler {
    static func focus() {
        let scrollingRoot = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        if scrollingRoot != nil {
            ScrollingFocusService.scrollRight()
        } else {
            FocusDirectionService.focus(.right)
        }
    }
}
