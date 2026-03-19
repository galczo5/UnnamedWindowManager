import Foundation

/// Split direction for containers and root slots.
enum Orientation {
    case horizontal
    case vertical

    var flipped: Orientation {
        self == .horizontal ? .vertical : .horizontal
    }
}
