import Foundation

/// A container slot whose children are split along an orientation — horizontal (left→right) or vertical (top→bottom).
struct SplitSlot {
    var id: UUID
    var parentId: UUID
    var size: CGSize
    var orientation: Orientation
    var children: [Slot]
    /// Share of the parent container's space in the split direction. Siblings sum to 1.0.
    var fraction: CGFloat = 1.0
}
