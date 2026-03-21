// Entry point for the focus-down shortcut.
struct FocusDownHandler {
    static func focus() {
        FocusDirectionService.focus(.down)
    }
}
