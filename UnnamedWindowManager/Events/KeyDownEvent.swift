import AppKit

// Event carrying key code, characters, and modifier flags for a global key-down.
struct KeyDownEvent: AppEvent {
    let keyCode: UInt16
    let characters: String?
    let modifiers: NSEvent.ModifierFlags
}
