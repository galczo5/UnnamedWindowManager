import Foundation
import AppKit

// Writes timestamped log lines to a file on a background queue.
final class Logger {
    static let shared = Logger()

    private let queue = DispatchQueue(label: "com.unnamed.logger", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private var fileHandle: FileHandle?

    private init() {
        let path = Config.logFilePath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
    }

    func log(_ message: String, file: String = #file, function: String = #function) {
        let timestamp = formatter.string(from: Date())
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let line = "[\(timestamp)] [\(filename)] \(function): \(message)\n"
        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            self?.fileHandle?.write(data)
        }
    }
}
