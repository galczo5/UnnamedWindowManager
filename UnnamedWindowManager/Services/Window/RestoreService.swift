import ApplicationServices

/// Restores a window's position and size to its pre-tile frame via the Accessibility API.
struct RestoreService {

    static func restore(_ slot: WindowSlot, element: AXUIElement) {
        guard let pos = slot.preTileOrigin, let size = slot.preTileSize else { return }
        AnimationService.shared.animate(key: slot, ax: element, to: pos, size: size)
    }
}
