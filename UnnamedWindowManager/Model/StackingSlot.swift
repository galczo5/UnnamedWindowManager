import Foundation

// A container where all children overlap at the same position; alignment and z-order are configurable.
// Height always fills the full screen height. Width is granted by the parent via fraction.
struct StackingSlot {
    var id: UUID
    var parentId: UUID
    var width: CGFloat
    var height: CGFloat
    var children: [WindowSlot]
    var align: StackingAlign
    var order: StackingOrder
    var fraction: CGFloat = 1.0
}
