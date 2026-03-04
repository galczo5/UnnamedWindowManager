//
//  CurrentOffset.swift
//  UnnamedWindowManager
//

import AppKit
import CoreGraphics

final class CurrentOffset {
    static let shared = CurrentOffset()
    private init() {}

    private(set) var value: Int = 0
    private var pendingOffsetWork: DispatchWorkItem?
    private(set) var isSuppressingFocusScroll = false

    func scrollRight() { setOffset(value + 100) }
    func scrollLeft()  { setOffset(value - 100) }

    func setOffset(_ newValue: Int) {
        value = max(0, newValue)
        suppressFocusScroll(for: 0.6)
        WindowSnapper.reapplyAll()
    }

    func suppressFocusScroll(for duration: TimeInterval) {
        isSuppressingFocusScroll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.isSuppressingFocusScroll = false
        }
    }

    func scheduleOffsetUpdate(forSlot slotIndex: Int) {
        pendingOffsetWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingOffsetWork = nil

            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleOffsetUpdate(forSlot: slotIndex)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let screen = NSScreen.main else { return }
                let slots = ManagedSlotRegistry.shared.allSlots()
                let newOffset = CurrentOffset.offsetForSlot(slotIndex, slots: slots, screen: screen)
                self.setOffset(newOffset)
            }
        }

        pendingOffsetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    static func offsetForSlot(_ slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> Int {
        guard !slots.isEmpty else { return 0 }
        let visible = screen.visibleFrame

        func naturalLeft(_ si: Int) -> CGFloat {
            var x = Config.gap
            for i in 0..<si { x += slots[i].width + Config.gap }
            return x
        }

        if slotIndex == 0 {
            return 0
        } else if slotIndex == slots.count - 1 {
            let left = naturalLeft(slotIndex)
            let raw  = left + slots[slotIndex].width + Config.gap - visible.width
            return Int(max(0, raw))
        } else {
            let left = naturalLeft(slotIndex)
            let raw  = left + slots[slotIndex].width / 2 - visible.width / 2
            return Int(max(0, raw))
        }
    }
}
