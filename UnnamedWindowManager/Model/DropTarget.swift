//
//  DropTarget.swift
//  UnnamedWindowManager
//

import Foundation

enum DropZone {
    case left, right, top, bottom, center
}

struct DropTarget {
    let window: WindowSlot
    let zone: DropZone
}
