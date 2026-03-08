// Entry point for the focus-right shortcut.
struct FocusRightHandler {
    static func focus() {
        FocusDirectionService.focus(.right)
    }
}
