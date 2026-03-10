import Foundation

/// A container slot whose children are stacked top-to-bottom.
struct VerticalSlot {
    var id: UUID
    var parentId: UUID
    var width: CGFloat
    var height: CGFloat
    var children: [Slot]
    var gaps: Bool = false
    /// Share of the parent container's space in the split direction. Siblings sum to 1.0.
    var fraction: CGFloat = 1.0
}
