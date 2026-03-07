import Foundation

// DropZone and DropTarget types used during window drag-and-drop to determine where to insert.
enum DropZone {
    case left, right, top, bottom, center
}

struct DropTarget {
    let window: WindowSlot
    let zone: DropZone
}
