import Foundation

/// A leaf slot holding one window.
/// Hashable/Equatable by identity (pid + windowHash) only.
struct WindowSlot: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
    var id: UUID
    var parentId: UUID
    /// Insertion order; used to identify the last-added leaf.
    var order: Int
    var size: CGSize
    var gaps: Bool = true
    /// Share of the parent container's space in the split direction. Siblings sum to 1.0.
    var fraction: CGFloat = 1.0
    /// Window origin before it was tiled (AX top-left coordinates). Set once at tile time.
    var preTileOrigin: CGPoint?
    /// Window size before it was tiled. Set once at tile time.
    var preTileSize: CGSize?
    /// True when this window was detected as part of a native macOS tab group.
    var isTabbed: Bool = false
    /// CGWindowIDs of all windows in the same native tab group, including self.
    var tabHashes: Set<UInt> = [] {
        didSet { if !tabHashes.isEmpty { tabHashes.insert(windowHash) } }
    }

    /// Returns true if `other` is a tab sibling of this slot (same tab group, different window).
    func isSameTabGroup(as other: WindowSlot) -> Bool {
        pid == other.pid && tabHashes.contains(other.windowHash)
    }

    /// Returns true if `hash` is a known tab sibling of this slot.
    func isSameTabGroup(hash: UInt) -> Bool {
        tabHashes.contains(hash)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.windowHash == rhs.windowHash
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(windowHash)
    }
}
