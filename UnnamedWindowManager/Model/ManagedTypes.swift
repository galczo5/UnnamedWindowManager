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
    var hidden: Bool = false
}

/// Drop zones per slot.
enum DropZone {
    case left    // create new slot before target
    case top     // add dragged window as first in target slot
    case center  // swap individual windows
    case bottom  // add dragged window as last in target slot
    case right   // create new slot after target
}

/// A drop target: which slot, which window within the slot, and which zone.
struct DropTarget {
    let slotIndex: Int
    let windowIndex: Int   // index of the specific window within the slot; used by .center
    let zone: DropZone
}
