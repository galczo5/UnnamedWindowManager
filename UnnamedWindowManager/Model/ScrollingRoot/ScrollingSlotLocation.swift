// Which slot a window occupies in a scrolling root.
enum ScrollingSlotLocation {
    case center
    case left(index: Int, count: Int)
    case right(index: Int, count: Int)
}
