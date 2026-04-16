import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid

// Status checks and System Settings jump points for the three macOS
// permissions the app requires: Accessibility, Input Monitoring, and
// Screen Recording. Consumed by the menu bar extra to display per-permission
// state and let the user jump straight to the relevant settings pane.
enum PermissionService {
    enum Permission: CaseIterable {
        case accessibility
        case inputMonitoring
        case screenRecording

        var title: String {
            switch self {
            case .accessibility:   return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            case .screenRecording: return "Screen Recording"
            }
        }

        var reason: String {
            switch self {
            case .accessibility:
                return "move, resize, and focus windows across apps"
            case .inputMonitoring:
                return "listen for global keyboard shortcuts"
            case .screenRecording:
                return "read window titles and on-screen window lists"
            }
        }

        var isGranted: Bool {
            switch self {
            case .accessibility:
                return AXIsProcessTrusted()
            case .inputMonitoring:
                return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            case .screenRecording:
                return CGPreflightScreenCaptureAccess()
            }
        }

        var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility:   anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            case .screenRecording: anchor = "Privacy_ScreenCapture"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    static func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    static var allGranted: Bool {
        Permission.allCases.allSatisfy { $0.isGranted }
    }
}
