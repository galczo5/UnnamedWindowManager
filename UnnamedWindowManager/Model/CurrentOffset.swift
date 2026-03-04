//
//  CurrentOffset.swift
//  UnnamedWindowManager
//

import CoreGraphics

final class CurrentOffset {
    static let shared = CurrentOffset()
    private init() {}

    private(set) var value: Int = 0

    func scrollRight() { setOffset(value + 100) }
    func scrollLeft()  { setOffset(value - 100) }

    func setOffset(_ newValue: Int) {
        value = max(0, newValue)
        WindowSnapper.reapplyAll()
    }
}
