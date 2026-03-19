import Foundation

/// The root of the slot tree for a single screen.
/// Always covers the full screen visible frame. Cannot appear inside Slot.
struct TilingRootSlot {
    var id: UUID
    var size: CGSize
    var orientation: Orientation
    var children: [Slot]
    var gaps: Bool = true
}
