import Foundation

// Unified slot type used throughout the layout tree; indirect breaks the recursive size cycle.
indirect enum Slot {
    case window(WindowSlot)
    case horizontal(HorizontalSlot)
    case vertical(VerticalSlot)

    var id: UUID {
        switch self {
        case .window(let w):     return w.id
        case .horizontal(let h): return h.id
        case .vertical(let v):   return v.id
        }
    }

    var parentId: UUID {
        get {
            switch self {
            case .window(let w):     return w.parentId
            case .horizontal(let h): return h.parentId
            case .vertical(let v):   return v.parentId
            }
        }
        set {
            switch self {
            case .window(var w):     w.parentId = newValue; self = .window(w)
            case .horizontal(var h): h.parentId = newValue; self = .horizontal(h)
            case .vertical(var v):   v.parentId = newValue; self = .vertical(v)
            }
        }
    }

    var width: CGFloat {
        switch self {
        case .window(let w):     return w.width
        case .horizontal(let h): return h.width
        case .vertical(let v):   return v.width
        }
    }

    var height: CGFloat {
        switch self {
        case .window(let w):     return w.height
        case .horizontal(let h): return h.height
        case .vertical(let v):   return v.height
        }
    }

    var fraction: CGFloat {
        get {
            switch self {
            case .window(let w):     return w.fraction
            case .horizontal(let h): return h.fraction
            case .vertical(let v):   return v.fraction
            }
        }
        set {
            switch self {
            case .window(var w):     w.fraction = newValue; self = .window(w)
            case .horizontal(var h): h.fraction = newValue; self = .horizontal(h)
            case .vertical(var v):   v.fraction = newValue; self = .vertical(v)
            }
        }
    }
}
