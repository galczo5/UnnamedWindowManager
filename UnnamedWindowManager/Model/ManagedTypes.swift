//
//  ManagedTypes.swift
//  UnnamedWindowManager
//

import Foundation

enum Orientation {
    case horizontal
    case vertical
}

indirect enum SlotContent {
    case window(ManagedWindow)
    case slots([ManagedSlot])
}

/// A tracked window — identity (pid + windowHash) plus its allocated size.
struct ManagedWindow: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
    var height: CGFloat
    var width: CGFloat

    // Hashable/Equatable by identity only (pid + windowHash).
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.windowHash == rhs.windowHash
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(windowHash)
    }
}

/// A slot in the layout tree — either a leaf holding one window, or a container holding child slots.
struct ManagedSlot {
    /// Leaf insertion counter. Used to identify the last-added leaf. 0 on container nodes.
    var order: Int = 0
    var width: CGFloat
    var height: CGFloat
    var orientation: Orientation
    var content: SlotContent
    /// When true, gap is applied when rendering this slot. True for window leaves and root; false for intermediate containers.
    var gaps: Bool = false
}

