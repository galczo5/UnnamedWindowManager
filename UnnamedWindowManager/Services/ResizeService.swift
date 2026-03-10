import AppKit

// Adjusts slot fractions in the tree when the user manually resizes a snapped window.
struct ResizeService {

    /// Minimum fraction any slot may shrink to (prevents zero-size tiles).
    private let minFraction: CGFloat = 0.05

    /// Apply a user resize to the tree.
    /// `actualSize` is the AX-reported rendered window size (gap insets excluded).
    func applyResize(key: WindowSlot, actualSize: CGSize, root: inout RootSlot) {
        guard let leaf = SlotTreeQueryService().findLeafSlot(key, in: root),
              case .window(let w) = leaf else { return }

        // Convert AX size (gap-excluded) back to slot space (gap-included).
        let gap = w.gaps ? Config.innerGap * 2 : 0
        let newSlotWidth  = actualSize.width  + gap
        let newSlotHeight = actualSize.height + gap

        let dw = newSlotWidth  - w.width
        let dh = newSlotHeight - w.height

        // Choose the axis with the larger delta.
        let resizeHorizontal = abs(dw) >= abs(dh)
        let delta = resizeHorizontal ? dw : dh

        guard abs(delta) > 1.0 else { return }

        adjustFractions(forSlotId: w.id, delta: delta, horizontal: resizeHorizontal, root: &root)
    }

    // MARK: - Private

    private func adjustFractions(
        forSlotId id: UUID,
        delta: CGFloat,
        horizontal: Bool,
        root: inout RootSlot
    ) {
        let splitsHorizontal = root.orientation == .horizontal
        let sizeInAxis = splitsHorizontal ? root.width : root.height
        adjustInChildren(&root.children,
                         targetId: id, delta: delta, horizontal: horizontal,
                         splitsHorizontal: splitsHorizontal, sizeInAxis: sizeInAxis)
    }

    private enum SearchResult { case notFound, adjusted, foundWrongAxis }

    /// Searches `children` for the slot with `targetId` and adjusts fractions.
    ///
    /// - `splitsHorizontal`: whether this container lays out children side-by-side.
    /// - `sizeInAxis`: the container's size in its split direction.
    ///
    /// Returns `.foundWrongAxis` when the target was found somewhere in the subtree
    /// but every container on the path to it splits in the wrong direction.
    /// The caller should then adjust the *child that contains the target* at its own level.
    @discardableResult
    private func adjustInChildren(
        _ children: inout [Slot],
        targetId: UUID,
        delta: CGFloat,
        horizontal: Bool,
        splitsHorizontal: Bool,
        sizeInAxis: CGFloat
    ) -> SearchResult {
        for i in children.indices {

            // Direct match at this level.
            if children[i].id == targetId {
                guard splitsHorizontal == horizontal, sizeInAxis > 0 else {
                    return .foundWrongAxis
                }
                applyFractionDelta(&children, targetIndex: i, fractionDelta: delta / sizeInAxis)
                return .adjusted
            }

            // Recurse into container children.
            switch children[i] {
            case .window:
                continue

            case .horizontal(var h):
                let result = adjustInChildren(
                    &h.children, targetId: targetId, delta: delta, horizontal: horizontal,
                    splitsHorizontal: true, sizeInAxis: h.width
                )
                switch result {
                case .notFound:
                    continue
                case .adjusted:
                    children[i] = .horizontal(h)
                    return .adjusted
                case .foundWrongAxis:
                    // Target is inside h but h's axis was wrong for the resize.
                    // Try adjusting h itself within this (the caller's) container.
                    guard splitsHorizontal == horizontal, sizeInAxis > 0 else {
                        return .foundWrongAxis
                    }
                    applyFractionDelta(&children, targetIndex: i, fractionDelta: delta / sizeInAxis)
                    return .adjusted
                }

            case .vertical(var v):
                let result = adjustInChildren(
                    &v.children, targetId: targetId, delta: delta, horizontal: horizontal,
                    splitsHorizontal: false, sizeInAxis: v.height
                )
                switch result {
                case .notFound:
                    continue
                case .adjusted:
                    children[i] = .vertical(v)
                    return .adjusted
                case .foundWrongAxis:
                    guard splitsHorizontal == horizontal, sizeInAxis > 0 else {
                        return .foundWrongAxis
                    }
                    applyFractionDelta(&children, targetIndex: i, fractionDelta: delta / sizeInAxis)
                    return .adjusted
                }
            }
        }
        return .notFound
    }

    /// Adjusts the fractions of `children[targetIndex]` and its nearest sibling by
    /// `+fractionDelta` / `-fractionDelta` respectively, then renormalises the pair
    /// so they sum to exactly `1.0 - sum(other children)`.
    private func applyFractionDelta(
        _ children: inout [Slot],
        targetIndex: Int,
        fractionDelta: CGFloat
    ) {
        guard children.count >= 2 else { return }
        let siblingIndex = targetIndex + 1 < children.count ? targetIndex + 1 : targetIndex - 1

        // Budget available to the pair after other children take their share.
        let otherSum = children.indices
            .filter { $0 != targetIndex && $0 != siblingIndex }
            .map { children[$0].fraction }
            .reduce(0, +)
        let available = max(2 * minFraction, 1.0 - otherSum)

        var newTarget  = children[targetIndex].fraction  + fractionDelta
        var newSibling = children[siblingIndex].fraction - fractionDelta

        // Clamp individually, then renormalise the pair to fill `available` exactly.
        newTarget  = max(minFraction, min(available - minFraction, newTarget))
        newSibling = max(minFraction, available - newTarget)

        children[targetIndex].fraction  = newTarget
        children[siblingIndex].fraction = newSibling
    }
}
