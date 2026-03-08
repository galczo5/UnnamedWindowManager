// Entry point for the focus-left shortcut.
struct FocusLeftHandler {
    static func focus() {
        FocusDirectionService.focus(.left)
    }
}
