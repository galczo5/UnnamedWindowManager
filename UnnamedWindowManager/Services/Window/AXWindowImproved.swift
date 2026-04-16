import ApplicationServices

// A window plus its native-tab siblings. `window` is the representative (selected)
// tab's AX element; `tabs` lists every AX element in the same tab group, or is empty
// when the window has no tab group.
struct AXWindowImproved {
    let window: AXUIElement
    let tabs: [AXUIElement]
}
