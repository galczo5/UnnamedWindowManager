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
    var width: CGFloat
    var height: CGFloat
    var gaps: Bool = true
    /// Share of the parent container's space in the split direction. Siblings sum to 1.0.
    var fraction: CGFloat = 1.0
    /// Window origin before it was tiled (AX top-left coordinates). Set once at tile time.
    var preTileOrigin: CGPoint?
    /// Window size before it was tiled. Set once at tile time.
    var preTileSize: CGSize?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.windowHash == rhs.windowHash
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(windowHash)
    }
}
