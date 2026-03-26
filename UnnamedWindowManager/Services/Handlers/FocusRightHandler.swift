// Entry point for the focus-right shortcut.
struct FocusRightHandler {
    static func focus() {
        let scrollingRoot = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()
        if scrollingRoot != nil {
            ScrollingFocusService.scrollRight()
        } else {
            FocusDirectionService.focus(.right)
        }
    }
}
