import Foundation
import simd

struct MainWindowSimulationStateSnapshot: Codable, Equatable, Sendable {
    static let physicsModuleKey = "physics"
    static let visualModuleKey = "visual"
    static let optimizationModuleKey = "optimization"

    var particleCount: Int
    var randomDistribution: Bool
    var particleTypes: Int
    var allParticlesIntercommunicate: Bool
    var movementDirectionX: Double
    var movementDirectionY: Double
    var movementDirectionZ: Double
    var timeScale: Double
    var sphereSize: Double
    var spectrumOffset: Double
    var showOptimizationInfo: Bool
    var showLeaderCommunicationLog: Bool
    var optimizationBlockingModeRawValue: String
    var protectLeaderFromUnload: Bool
    var assignedPhysicsModulePath: String?
    var assignedVisualModulePath: String?
    var assignedOptimizationModulePath: String?

    static let `default` = MainWindowSimulationStateSnapshot(
        particleCount: 20_000,
        randomDistribution: true,
        particleTypes: 6,
        allParticlesIntercommunicate: true,
        movementDirectionX: 0.82,
        movementDirectionY: 0.18,
        movementDirectionZ: 0.12,
        timeScale: 1.0,
        sphereSize: 0.008,
        spectrumOffset: 0.0,
        showOptimizationInfo: false,
        showLeaderCommunicationLog: false,
        optimizationBlockingModeRawValue: OptimizationBlockingMode.fullBlocking.rawValue,
        protectLeaderFromUnload: true,
        assignedPhysicsModulePath: nil,
        assignedVisualModulePath: nil,
        assignedOptimizationModulePath: nil
    )

    var editorState: SimulationEditorState {
        SimulationEditorState(
            physicsState: physicsState,
            visualState: visualState,
            optimizationState: optimizationState,
            debugSettings: debugSettings,
            assignedModulePaths: assignedModules
        )
    }

    var physicsState: PhysicsModuleState {
        PhysicsModuleState(
            particleCount: particleCount,
            randomDistribution: randomDistribution,
            particleTypes: particleTypes,
            allParticlesIntercommunicate: allParticlesIntercommunicate,
            movementDirection: SIMD3<Double>(movementDirectionX, movementDirectionY, movementDirectionZ),
            timeScale: timeScale
        )
    }

    var visualState: VisualModuleState {
        VisualModuleState(
            sphereSize: sphereSize,
            spectrumOffset: spectrumOffset,
            showOptimizationInfo: showOptimizationInfo
        )
    }

    var optimizationState: OptimizationModuleState {
        OptimizationModuleState(
            showLeaderCommunicationLog: showLeaderCommunicationLog,
            blockingMode: OptimizationBlockingMode(rawValue: optimizationBlockingModeRawValue) ?? .fullBlocking
        )
    }

    var debugSettings: DebugSettingsState {
        DebugSettingsState(protectLeaderFromUnload: protectLeaderFromUnload)
    }

    var assignedModules: [String: String] {
        var result: [String: String] = [:]
        if let assignedPhysicsModulePath { result[Self.physicsModuleKey] = assignedPhysicsModulePath }
        if let assignedVisualModulePath { result[Self.visualModuleKey] = assignedVisualModulePath }
        if let assignedOptimizationModulePath { result[Self.optimizationModuleKey] = assignedOptimizationModulePath }
        return result
    }

    static func from(
        physicsState: PhysicsModuleState,
        visualState: VisualModuleState,
        optimizationState: OptimizationModuleState,
        debugSettings: DebugSettingsState,
        assignedModulePaths: [String: String]
    ) -> MainWindowSimulationStateSnapshot {
        MainWindowSimulationStateSnapshot(
            particleCount: physicsState.particleCount,
            randomDistribution: physicsState.randomDistribution,
            particleTypes: physicsState.particleTypes,
            allParticlesIntercommunicate: physicsState.allParticlesIntercommunicate,
            movementDirectionX: physicsState.movementDirection.x,
            movementDirectionY: physicsState.movementDirection.y,
            movementDirectionZ: physicsState.movementDirection.z,
            timeScale: physicsState.timeScale,
            sphereSize: visualState.sphereSize,
            spectrumOffset: visualState.spectrumOffset,
            showOptimizationInfo: visualState.showOptimizationInfo,
            showLeaderCommunicationLog: optimizationState.showLeaderCommunicationLog,
            optimizationBlockingModeRawValue: optimizationState.blockingMode.rawValue,
            protectLeaderFromUnload: debugSettings.protectLeaderFromUnload,
            assignedPhysicsModulePath: assignedModulePaths[Self.physicsModuleKey],
            assignedVisualModulePath: assignedModulePaths[Self.visualModuleKey],
            assignedOptimizationModulePath: assignedModulePaths[Self.optimizationModuleKey]
        )
    }

    static func from(editorState: SimulationEditorState) -> MainWindowSimulationStateSnapshot {
        from(
            physicsState: editorState.physicsState,
            visualState: editorState.visualState,
            optimizationState: editorState.optimizationState,
            debugSettings: editorState.debugSettings,
            assignedModulePaths: editorState.assignedModulePaths
        )
    }
}

@MainActor
final class MainWindowSimulationStateStore {
    static let shared = MainWindowSimulationStateStore()

    private let store = CodableDefaultsStore<MainWindowSimulationStateSnapshot>(
        defaultsKey: "PhysicsSim.MainWindowSimulationState.v1",
        queueLabel: "PhysicsSim.MainWindowSimulationStateStore"
    )

    func load() -> MainWindowSimulationStateSnapshot {
        store.load(fallback: .default)
    }

    func save(_ snapshot: MainWindowSimulationStateSnapshot) {
        store.save(snapshot)
    }
}

@MainActor
final class MainWindowEditorSettingsStore: ObservableObject {
    static let shared = MainWindowEditorSettingsStore()

    @Published private(set) var editorState: SimulationEditorState

    init() {
        self.editorState = MainWindowSimulationStateStore.shared.load().editorState
    }

    func setPhysicsState(_ nextState: PhysicsModuleState) {
        let previous = editorState.physicsState
        updateEditorState {
            $0.physicsState = nextState
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_physics_state",
            details: [
                "from": InteractionSnapshotFormat.physics(previous),
                "to": InteractionSnapshotFormat.physics(nextState),
            ]
        )
    }

    func setVisualState(_ nextState: VisualModuleState) {
        let previous = editorState.visualState
        updateEditorState {
            $0.visualState = nextState
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_visual_state",
            details: [
                "from": InteractionSnapshotFormat.visual(previous),
                "to": InteractionSnapshotFormat.visual(nextState),
            ]
        )
    }

    func setOptimizationState(_ nextState: OptimizationModuleState) {
        let previous = editorState.optimizationState
        updateEditorState {
            $0.optimizationState = nextState
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_optimization_state",
            details: [
                "from": InteractionSnapshotFormat.optimization(previous),
                "to": InteractionSnapshotFormat.optimization(nextState),
            ]
        )
    }

    func setDebugSettings(_ nextState: DebugSettingsState) {
        let previous = editorState.debugSettings
        updateEditorState {
            $0.debugSettings = nextState
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_debug_settings",
            details: [
                "from": InteractionSnapshotFormat.debug(previous),
                "to": InteractionSnapshotFormat.debug(nextState),
            ]
        )
    }

    func setAssignedModulePath(_ path: String?, for kind: ModuleKind) {
        let previous = editorState.assignedModulePaths[kind.rawValue]
        updateEditorState {
            if let path {
                $0.assignedModulePaths[kind.rawValue] = path
            } else {
                $0.assignedModulePaths.removeValue(forKey: kind.rawValue)
            }
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_assigned_module_path",
            details: [
                "kind": kind.rawValue,
                "from": InteractionSnapshotFormat.assignedModulePath(previous),
                "to": InteractionSnapshotFormat.assignedModulePath(path),
            ]
        )
    }

    func assignedModulePath(for kind: ModuleKind) -> String? {
        editorState.assignedModulePaths[kind.rawValue]
    }

    func normalizeAssignedModulePaths(availableFiles: [ModuleFile]) {
        var nextAssignments = editorState.assignedModulePaths
        var didChange = false

        for kind in ModuleKind.allCases {
            guard let storedPath = nextAssignments[kind.rawValue],
                  let resolvedFile = SimulationConfigurationDerivation.resolvedAssignedModuleFile(
                    for: kind,
                    assignedPath: storedPath,
                    availableFiles: availableFiles
                  ) else {
                continue
            }

            let resolvedPath = resolvedFile.url.path
            if resolvedPath != storedPath {
                nextAssignments[kind.rawValue] = resolvedPath
                didChange = true
            }
        }

        guard didChange else { return }
        updateEditorState {
            $0.assignedModulePaths = nextAssignments
        }
    }

    private func updateEditorState(_ mutate: (inout SimulationEditorState) -> Void) {
        var nextEditorState = editorState
        mutate(&nextEditorState)
        editorState = nextEditorState
        persist()
    }

    private func persist() {
        MainWindowSimulationStateStore.shared.save(.from(editorState: editorState))
    }
}
