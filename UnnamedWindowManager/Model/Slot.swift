import Foundation

enum Orientation {
    case horizontal
    case vertical
}

/// A leaf slot holding one window.
/// Hashable/Equatable by identity (pid + windowHash) only.
struct WindowSlot: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
    var id: UUID
    var parentId: UUID
    /// Insertion order; used to identify the last-added leaf.
    var order: Int
    var width: CGFloat
    var height: CGFloat
    var gaps: Bool = true
    /// Share of the parent container's space in the split direction. Siblings sum to 1.0.
    var fraction: CGFloat = 1.0
    /// Window origin before it was snapped (AX top-left coordinates). Set once at snap time.
    var preSnapOrigin: CGPoint?
    /// Window size before it was snapped. Set once at snap time.
    var preSnapSize: CGSize?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.windowHash == rhs.windowHash
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(windowHash)
    }
}

/// A container slot whose children are arranged side-by-side (left → right).
struct HorizontalSlot {
    var id: UUID
    var parentId: UUID
    var width: CGFloat
    var height: CGFloat
    var children: [Slot]
    var gaps: Bool = false
    /// Share of the parent container's space in the split direction. Siblings sum to 1.0.
    var fraction: CGFloat = 1.0
}

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
