import AppKit

// Maps config color name strings to NSColor values.
struct SystemColor {
    static func resolve(_ name: String) -> NSColor? {
        switch name.lowercased() {
        case "blue":    return .systemBlue
        case "red":     return .systemRed
        case "green":   return .systemGreen
        case "orange":  return .systemOrange
        case "yellow":  return .systemYellow
        case "pink":    return .systemPink
        case "purple":  return .systemPurple
        case "teal":    return .systemTeal
        case "indigo":  return .systemIndigo
        case "brown":   return .systemBrown
        case "mint":    return .systemMint
        case "cyan":    return .systemCyan
        case "gray":    return .systemGray
        case "black":   return .black
        case "white":   return .white
        default:        return nil
        }
    }
}
