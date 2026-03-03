//
//  Config.swift
//  UnnamedWindowManager
//

import CoreGraphics
import AppKit

enum Config {
    /// Gap between snapped windows and screen edges (points).
    static let gap: CGFloat = 10
    /// Fallback width fraction of the visible screen when a window's size cannot be read.
    static let fallbackWidthFraction: CGFloat = 0.4
    /// Maximum width of a snapped window as a fraction of the visible screen width.
    static let maxWidthFraction: CGFloat = 0.80
    /// Maximum height of a snapped window: full visible height minus top and bottom gaps.
    /// Expressed as a multiplier; effective cap = visible.height × maxHeightFraction − 2 × gap.
    static let maxHeightFraction: CGFloat = 1.0
    /// Fraction of a window's width that counts as the left or right drop zone (each side).
    static let dropZoneFraction: CGFloat = 0.10
    /// Fraction of a window's height (from the bottom) that activates the vertical-split drop zone.
    static let dropZoneBottomFraction: CGFloat = 0.20
    /// Corner radius of the swap-target overlay rectangle (points).
    static let overlayCornerRadius: CGFloat = 8
    /// Border width of the swap-target overlay rectangle (points).
    static let overlayBorderWidth: CGFloat = 3
    /// Fill color of the swap-target overlay rectangle.
    static let overlayFillColor: NSColor = .systemBlue.withAlphaComponent(0.2)
    /// Border color of the swap-target overlay rectangle.
    static let overlayBorderColor: NSColor = .systemBlue.withAlphaComponent(0.8)
}
