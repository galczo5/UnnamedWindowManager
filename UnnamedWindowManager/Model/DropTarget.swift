//
//  DropTarget.swift
//  UnnamedWindowManager
//

import Foundation

enum DropZone {
    case left, right, top, bottom
}

struct DropTarget {
    let window: WindowSlot
    let zone: DropZone
}
