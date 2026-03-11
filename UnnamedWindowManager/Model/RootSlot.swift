import Foundation

// A layout root — either a recursive tiling tree or a scrolling zone layout.
enum RootSlot {
    case tiling(TilingRootSlot)
    case scrolling(ScrollingRootSlot)

    var id: UUID {
        switch self {
        case .tiling(let r): return r.id
        case .scrolling(let r): return r.id
        }
    }
}
