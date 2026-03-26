// Entry point for the focus-left shortcut.
struct FocusLeftHandler {
    static func focus() {
        let scrollingRoot = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()
        if scrollingRoot != nil {
            ScrollingFocusService.scrollLeft()
        } else {
            FocusDirectionService.focus(.left)
        }
    }
}
