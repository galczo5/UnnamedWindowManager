import Foundation

// The root of a scrolling layout: a center slot flanked by optional left and right slots.
struct ScrollingRootSlot {
    var id: UUID
    var width: CGFloat
    var height: CGFloat
    // User-set fraction of screen width for the center slot. nil = default 0.8.
    var centerWidthFraction: CGFloat? = nil
    var left: Slot?
    var center: Slot
    var right: Slot?
}
