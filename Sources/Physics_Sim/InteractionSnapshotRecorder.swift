import Foundation

struct InteractionSnapshotPanelState: Encodable {
    let id: String
    let type: String
    let zone: String
    let isCollapsed: Bool
}

struct InteractionSnapshotState: Encodable {
    let transportState: String
    let coordinatorSimulationState: String
    let sessionSimulationState: String
    let renderState: String
    let activeModules: String
    let editorPhysicsState: String
    let editorVisualState: String
    let editorOptimizationState: String
    let debugSettingsState: String
    let validationIssue: String?
    let projectedBytes: UInt64
    let viewportRuntimeError: String?
    let selectedFile: String?
    let debugMetricsVisible: Bool
    let panels: [InteractionSnapshotPanelState]
    let performanceMetrics: String
}

struct InteractionSnapshotEntry: Encodable {
    let timestamp: String
    let kind: String
    let label: String
    let details: [String: String]
    let snapshot: InteractionSnapshotState?
}

private struct InteractionSnapshotDump: Encodable {
    let generatedAt: String
    let durationSeconds: Double
    let sampleIntervalSeconds: Double
    let entryCount: Int
    let entries: [InteractionSnapshotEntry]
}

enum InteractionSnapshotFormat {
    static func physics(_ state: PhysicsModuleState) -> String {
        "count=\(state.particleCount) random=\(state.randomDistribution) types=\(state.particleTypes) intercommunicate=\(state.allParticlesIntercommunicate) direction=(\(format(state.movementDirection.x)),\(format(state.movementDirection.y)),\(format(state.movementDirection.z))) timeScale=\(format(state.timeScale))"
    }

    static func visual(_ state: VisualModuleState) -> String {
        "sphereSize=\(format(state.sphereSize)) spectrumOffset=\(format(state.spectrumOffset)) showOptimizationInfo=\(state.showOptimizationInfo)"
    }

    static func optimization(_ state: OptimizationModuleState) -> String {
        "blockingMode=\(state.blockingMode.rawValue) showLeaderCommunicationLog=\(state.showLeaderCommunicationLog)"
    }

    static func debug(_ state: DebugSettingsState) -> String {
        "protectLeaderFromUnload=\(state.protectLeaderFromUnload)"
    }

    static func viewport(_ state: SimulationViewportState) -> String {
        "transport=\(state.transportState.rawValue) count=\(state.particleCount) random=\(state.randomDistribution) types=\(state.particleTypes) intercommunicate=\(state.allParticlesIntercommunicate) direction=(\(format(Double(state.movementDirection.x))),\(format(Double(state.movementDirection.y))),\(format(Double(state.movementDirection.z)))) timeScale=\(format(Double(state.timeScale))) sphereSize=\(format(Double(state.sphereSize))) spectrumOffset=\(format(Double(state.spectrumOffset))) showOptimizationInfo=\(state.showOptimizationInfo) showLeaderCommunicationLog=\(state.showLeaderCommunicationLog) blockingMode=\(state.optimizationBlockingMode.rawValue)"
    }

    static func renderState(_ state: SimulationRuntime.RenderState) -> String {
        "activeParticleCount=\(state.activeParticleCount) particleCapacity=\(state.particleCapacity) hasParticleBuffer=\(state.particleBuffer != nil) hasDebugLineBuffer=\(state.debugLineBuffer != nil) debugRenderSegments=\(state.debugRenderSegments.count)"
    }

    static func activeModules(_ modules: ActiveModuleSet) -> String {
        "physics=\(modules.physics.name) visual=\(modules.visual.name) optimization=\(modules.optimization.name)"
    }

    static func performanceMetrics(_ metrics: SimulationPerformanceMetrics) -> String {
        "memoryUsedBytes=\(metrics.memoryUsedBytes) averageFPS=\(format(metrics.averageFPS)) averageUPS=\(format(metrics.averageUPS)) leaderInteractionsPerSecond=\(format(metrics.leaderInteractionsPerSecond)) sampleWindowSeconds=\(format(metrics.sampleWindowSeconds))"
    }

    static func assignedModulePath(_ path: String?) -> String {
        path ?? "<nil>"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

@MainActor
final class InteractionSnapshotRecorder: ObservableObject {
    static let shared = InteractionSnapshotRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var lastOutputPath: String?

    private let durationSeconds: TimeInterval = 15
    private let sampleIntervalSeconds: TimeInterval = 0.1
    private let formatter = ISO8601DateFormatter()
    private var entries: [InteractionSnapshotEntry] = []
    private var snapshotProvider: (() -> InteractionSnapshotState)?
    private var recordingTask: Task<Void, Never>?

    init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func startRecording(snapshotProvider: @escaping () -> InteractionSnapshotState) {
        guard !isRecording else { return }

        self.snapshotProvider = snapshotProvider
        self.entries = []
        self.isRecording = true
        self.remainingSeconds = Int(durationSeconds)
        self.lastOutputPath = nil

        record(event: "interaction_snapshot_started")
        appendSnapshot(label: "initial")

        recordingTask = Task { [weak self] in
            guard let self else { return }

            let start = Date()
            while true {
                do {
                    try await Task.sleep(for: .seconds(sampleIntervalSeconds))
                } catch {
                    return
                }

                if Task.isCancelled {
                    return
                }

                await MainActor.run {
                    let elapsed = Date().timeIntervalSince(start)
                    let remaining = max(0, Int(ceil(self.durationSeconds - elapsed)))
                    self.remainingSeconds = remaining
                    self.appendSnapshot(label: "sample")
                }

                if Date().timeIntervalSince(start) >= durationSeconds {
                    break
                }
            }

            await MainActor.run {
                self.finishRecording()
            }
        }
    }

    func record(event label: String, details: [String: String] = [:]) {
        guard isRecording else { return }
        entries.append(
            InteractionSnapshotEntry(
                timestamp: formatter.string(from: Date()),
                kind: "event",
                label: label,
                details: details,
                snapshot: nil
            )
        )
    }

    private func appendSnapshot(label: String) {
        guard isRecording, let snapshotProvider else { return }
        entries.append(
            InteractionSnapshotEntry(
                timestamp: formatter.string(from: Date()),
                kind: "snapshot",
                label: label,
                details: [:],
                snapshot: snapshotProvider()
            )
        )
    }

    private func finishRecording() {
        appendSnapshot(label: "final")
        record(event: "interaction_snapshot_finished")
        writeDump()
        isRecording = false
        remainingSeconds = 0
        snapshotProvider = nil
        recordingTask = nil
    }

    private func writeDump() {
        let dump = InteractionSnapshotDump(
            generatedAt: formatter.string(from: Date()),
            durationSeconds: durationSeconds,
            sampleIntervalSeconds: sampleIntervalSeconds,
            entryCount: entries.count,
            entries: entries
        )

        do {
            let url = Self.outputURL
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(dump)
            try data.write(to: url, options: .atomic)
            lastOutputPath = url.path
        } catch {
            lastOutputPath = "write_failed: \(error.localizedDescription)"
        }
    }

    static var outputURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".home", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("interaction_snapshot.log", isDirectory: false)
    }
}
