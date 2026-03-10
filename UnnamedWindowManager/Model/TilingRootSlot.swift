import Foundation

/// The root of the slot tree for a single screen.
/// Always covers the full screen visible frame. Cannot appear inside Slot.
struct TilingRootSlot {
    var id: UUID
    var width: CGFloat
    var height: CGFloat
    var orientation: Orientation
    var children: [Slot]
    var gaps: Bool = true
}
