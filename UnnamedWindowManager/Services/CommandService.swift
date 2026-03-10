import Foundation

// Runs shell commands from user-configured keyboard shortcuts.
struct CommandService {
    static func execute(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            do {
                try process.run()
            } catch {
                Logger.shared.log("CommandService: failed to run '\(command)' — \(error.localizedDescription)")
            }
        }
    }
}
