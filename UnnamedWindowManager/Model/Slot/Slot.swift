import Foundation

// Unified slot type used throughout the layout tree; indirect breaks the recursive size cycle.
indirect enum Slot {
    case window(WindowSlot)
    case split(SplitSlot)
    case stacking(StackingSlot)

    var id: UUID {
        switch self {
        case .window(let w):   return w.id
        case .split(let s):    return s.id
        case .stacking(let s): return s.id
        }
    }

    var parentId: UUID {
        get {
            switch self {
            case .window(let w):   return w.parentId
            case .split(let s):    return s.parentId
            case .stacking(let s): return s.parentId
            }
        }
        set {
            switch self {
            case .window(var w):   w.parentId = newValue; self = .window(w)
            case .split(var s):    s.parentId = newValue; self = .split(s)
            case .stacking(var s): s.parentId = newValue; self = .stacking(s)
            }
        }
    }

    var size: CGSize {
        switch self {
        case .window(let w):   return w.size
        case .split(let s):    return s.size
        case .stacking(let s): return s.size
        }
    }

    var fraction: CGFloat {
        get {
            switch self {
            case .window(let w):   return w.fraction
            case .split(let s):    return s.fraction
            case .stacking(let s): return s.fraction
            }
        }
        set {
            switch self {
            case .window(var w):   w.fraction = newValue; self = .window(w)
            case .split(var s):    s.fraction = newValue; self = .split(s)
            case .stacking(var s): s.fraction = newValue; self = .stacking(s)
            }
        }
    }
}
