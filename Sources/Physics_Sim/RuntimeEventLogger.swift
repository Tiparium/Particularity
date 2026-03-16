import Foundation

enum RuntimeEventLogger {
    private static let queue = DispatchQueue(label: "physics-sim.runtime-logger")
    private static let maxEntries = 100

    static func log(_ message: String) {
        queue.async {
            let url = logFileURL()
            let formatter = ISO8601DateFormatter()
            let line = "[\(formatter.string(from: Date()))] \(message)\n"

            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let existingText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                var lines = existingText
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                lines.append(String(line.dropLast()))
                if lines.count > maxEntries {
                    lines.removeFirst(lines.count - maxEntries)
                }
                let output = lines.joined(separator: "\n") + "\n"
                try output.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                fputs("RuntimeEventLogger failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func logFileURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".home", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("runtime.log", isDirectory: false)
    }
}
