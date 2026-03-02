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
    /// Corner radius of the swap-target overlay rectangle (points).
    static let overlayCornerRadius: CGFloat = 8
    /// Border width of the swap-target overlay rectangle (points).
    static let overlayBorderWidth: CGFloat = 3
    /// Fill color of the swap-target overlay rectangle.
    static let overlayFillColor: NSColor = .systemBlue.withAlphaComponent(0.2)
    /// Border color of the swap-target overlay rectangle.
    static let overlayBorderColor: NSColor = .systemBlue.withAlphaComponent(0.8)
}
