//
//  ManagedTypes.swift
//  UnnamedWindowManager
//

import Foundation

/// A tracked window — identity (pid + windowHash) plus its allocated height.
struct ManagedWindow: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
    var height: CGFloat

    // Hashable/Equatable by identity only (pid + windowHash).
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.windowHash == rhs.windowHash
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(windowHash)
    }
}

/// A vertical column — owns its width, holds ordered windows top-to-bottom.
struct ManagedSlot {
    var width: CGFloat
    var windows: [ManagedWindow]
}

/// Drop zones target a slot by index.
enum DropZone {
    case left    // insert dragged slot before target
    case center  // swap dragged and target slots
    case right   // insert dragged slot after target
    case bottom  // add dragged window into target slot
}

/// A drop target: which slot and which zone the cursor is in.
struct DropTarget {
    let slotIndex: Int
    let zone: DropZone
}
