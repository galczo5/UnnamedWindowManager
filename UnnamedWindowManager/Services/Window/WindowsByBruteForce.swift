import AppKit
import ApplicationServices
import Foundation

// Private AX SPI: creates an AXUIElement for the given remote token. Used to
// enumerate windows on other Spaces, which `kAXWindowsAttribute` does not return.
@_silgen_name("_AXUIElementCreateWithRemoteToken") @discardableResult
private func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

// Probes AX element IDs 0..1000 for the given PID, returning elements whose
// subrole is AXStandardWindow or AXDialog. Time-capped at 0.1s. This catches
// windows on other Spaces that `kAXWindowsAttribute` doesn't expose. Technique
// borrowed from alt-tab-macos via UnnamedMenu.
func windowsByBruteForce(_ pid: pid_t) -> [AXUIElement] {
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
    var results: [AXUIElement] = []
    let start = Date()
    for id: UInt64 in 0..<1000 {
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
        guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subroleStr = subrole as? String,
           [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subroleStr) {
            results.append(element)
        }
        if Date().timeIntervalSince(start) > 0.1 { break }
    }
    return results
}
