import ApplicationServices
import Foundation

// Debug-only logger for the tab recognizer. Invoked from the app's Debug menu —
// never fires on ordinary focus/tile paths.
enum TabRecognizerDebug {

    static func log() {
        let all = TabRecognizer.collectAllWindows()
        var lines: [String] = ["TabRecognizer.debug: \(all.count) window(s)"]
        for window in all {
            lines.append("  \(describe(window))")
        }
        Logger.shared.log(lines.joined(separator: "\n"))

        let groups = TabRecognition.recognize(windows: all)
        var groupLines: [String] = ["TabRecognizer.debug: recognize → \(groups.count) group(s)"]
        for (i, group) in groups.enumerated() {
            groupLines.append("- group \(i + 1): \(describe(group.window))")
            for (j, tab) in group.tabs.enumerated() {
                groupLines.append("   - tab \(j + 1): \(describe(tab))")
            }
        }
        Logger.shared.log(groupLines.joined(separator: "\n"))
    }

    private static func describe(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let wid = windowID(of: element)
        let widStr = wid.map(String.init) ?? "nil"
        let hashStr = wid.map { String(UInt($0)) }
            ?? String(UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque()))
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""
        return "Window(pid: \(pid), id: \(widStr), hash: \(hashStr), title: \"\(title)\")"
    }
}
