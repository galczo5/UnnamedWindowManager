//
//  Config.swift
//  UnnamedWindowManager
//

import CoreGraphics

enum Config {
    /// Gap between snapped windows and screen edges (points).
    static let gap: CGFloat = 10
    /// Fallback width fraction of the visible screen when a window's size cannot be read.
    static let fallbackWidthFraction: CGFloat = 0.4
}
