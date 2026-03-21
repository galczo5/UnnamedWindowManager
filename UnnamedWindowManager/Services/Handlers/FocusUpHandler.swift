// Entry point for the focus-up shortcut.
struct FocusUpHandler {
    static func focus() {
        FocusDirectionService.focus(.up)
    }
}
