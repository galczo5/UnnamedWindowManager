//
//  SnapTypes.swift
//  UnnamedWindowManager
//

import Foundation

struct SnapKey: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
}

struct SnapEntry {
    var slot: Int
    var width: CGFloat
    var height: CGFloat
}

enum DropZone {
    case left    // insert dragged window before target
    case center  // swap dragged and target
    case right   // insert dragged window after target
}

struct DropTarget {
    let key:  SnapKey
    let zone: DropZone
}
