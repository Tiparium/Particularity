import AppKit
import Foundation

extension Notification.Name {
    static let testingAPICommand = Notification.Name("PhysicsSim.TestingAPICommand")
}

enum TestingAPICommand: String, Codable {
    case startSimulation = "start_simulation"
    case togglePausePlay = "toggle_pause_play"
    case stopSimulation = "stop_simulation"
    case dumpState = "dump_state"
    case closeMainWindow = "close_main_window"
    case openMainWindow = "open_main_window"
}

struct TestingAPICommandEnvelope: Codable {
    let command: TestingAPICommand
}

@MainActor
final class WindowCommandCenter {
    static let shared = WindowCommandCenter()

    func closeMainWindow() {
        let candidate = NSApp.windows.first { $0.isVisible } ?? NSApp.windows.first
        candidate?.performClose(nil)
    }

    func reopenMainWindow() {
        let candidate = NSApp.windows.first
        candidate?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class TestingCommandHandler {
    static let shared = TestingCommandHandler()

    private let pollInterval: TimeInterval = 0.25
    private let commandsURL: URL = {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return root.appendingPathComponent(".home/runtime/testing_api_commands.jsonl")
    }()

    private var pollTimer: DispatchSourceTimer?
    private var consumedByteOffset: UInt64 = 0

    func start() {
        ensureInboxExists()
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollInbox()
        }
        pollTimer = timer
        timer.resume()
    }

    private func ensureInboxExists() {
        let directory = commandsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: commandsURL.path) {
            FileManager.default.createFile(atPath: commandsURL.path, contents: Data())
        }
    }

    private func pollInbox() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: commandsURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return
        }

        let length = fileSize.uint64Value
        if length < consumedByteOffset {
            consumedByteOffset = 0
        }
        guard length > consumedByteOffset else { return }

        guard let handle = try? FileHandle(forReadingFrom: commandsURL) else { return }
        defer { try? handle.close() }

        try? handle.seek(toOffset: consumedByteOffset)
        let newData = handle.readDataToEndOfFile()
        consumedByteOffset = length

        guard !newData.isEmpty, let newText = String(data: newData, encoding: .utf8) else { return }
        let lines = newText.split(separator: "\n")
        for line in lines {
            processLine(String(line))
        }
    }

    private func processLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let envelope = try JSONDecoder().decode(TestingAPICommandEnvelope.self, from: data)
            RuntimeEventLogger.log("testing_api command=\(envelope.command.rawValue)")
            NotificationCenter.default.post(name: .testingAPICommand, object: envelope.command)
        } catch {
            RuntimeEventLogger.log("testing_api invalid_command error=\(error.localizedDescription)")
        }
    }
}
