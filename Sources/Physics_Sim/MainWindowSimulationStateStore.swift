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
    var mlPlaybackRecipe: Int
    var mlPlaybackNormalizationMode: Int
    var playbackSurfaceMeshEnabled: Bool
    var playbackSurfaceSmoothing: Double
    var playbackFrontLayerVisible: Bool
    var playbackMiddleLayerVisible: Bool
    var playbackFinalLayerVisible: Bool
    var playbackFrontLayerSlot: Int
    var playbackMiddleLayerSlot: Int
    var playbackFinalLayerSlot: Int
    var playbackFrontLayerHorizontalOffset: Double
    var playbackMiddleLayerHorizontalOffset: Double
    var playbackFinalLayerHorizontalOffset: Double
    var playbackFrontLayerOffset: Double
    var playbackMiddleLayerOffset: Double
    var playbackFinalLayerOffset: Double
    var playbackTimeScale: Double
    var playbackInterpolationEnabled: Bool
    var showLeaderCommunicationLog: Bool
    var fixedGridSubdivisions: Int
    var fixedGridSubspaceCap: Int
    var fixedGridNeighborReadMode: String
    var protectLeaderFromUnload: Bool
    var assignedPhysicsModulePath: String?
    var assignedVisualModulePath: String?
    var assignedOptimizationModulePath: String?

    private enum CodingKeys: String, CodingKey {
        case particleCount
        case randomDistribution
        case particleTypes
        case allParticlesIntercommunicate
        case movementDirectionX
        case movementDirectionY
        case movementDirectionZ
        case timeScale
        case sphereSize
        case spectrumOffset
        case showOptimizationInfo
        case mlPlaybackRecipe
        case mlPlaybackNormalizationMode
        case playbackSurfaceMeshEnabled
        case playbackSurfaceSmoothing
        case playbackFrontLayerVisible
        case playbackMiddleLayerVisible
        case playbackFinalLayerVisible
        case playbackFrontLayerSlot
        case playbackMiddleLayerSlot
        case playbackFinalLayerSlot
        case playbackFrontLayerHorizontalOffset
        case playbackMiddleLayerHorizontalOffset
        case playbackFinalLayerHorizontalOffset
        case playbackFrontLayerOffset
        case playbackMiddleLayerOffset
        case playbackFinalLayerOffset
        case playbackTimeScale
        case playbackInterpolationEnabled
        case showLeaderCommunicationLog
        case fixedGridSubdivisions
        case fixedGridSubspaceCap
        case fixedGridNeighborReadMode
        case protectLeaderFromUnload
        case assignedPhysicsModulePath
        case assignedVisualModulePath
        case assignedOptimizationModulePath
    }

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
        mlPlaybackRecipe: MLPlaybackVisualRecipe.typeSpectrum.rawValue,
        mlPlaybackNormalizationMode: MLPlaybackNormalizationMode.global.rawValue,
        playbackSurfaceMeshEnabled: true,
        playbackSurfaceSmoothing: 0.35,
        playbackFrontLayerVisible: true,
        playbackMiddleLayerVisible: true,
        playbackFinalLayerVisible: true,
        playbackFrontLayerSlot: 0,
        playbackMiddleLayerSlot: 0,
        playbackFinalLayerSlot: 0,
        playbackFrontLayerHorizontalOffset: -0.24,
        playbackMiddleLayerHorizontalOffset: 0.0,
        playbackFinalLayerHorizontalOffset: 0.24,
        playbackFrontLayerOffset: 0.32,
        playbackMiddleLayerOffset: 0.0,
        playbackFinalLayerOffset: -0.32,
        playbackTimeScale: 1.0,
        playbackInterpolationEnabled: false,
        showLeaderCommunicationLog: false,
        fixedGridSubdivisions: 8,
        fixedGridSubspaceCap: 2,
        fixedGridNeighborReadMode: FixedGridNeighborReadMode.scratch.rawValue,
        protectLeaderFromUnload: true,
        assignedPhysicsModulePath: nil,
        assignedVisualModulePath: nil,
        assignedOptimizationModulePath: nil
    )

    init(
        particleCount: Int,
        randomDistribution: Bool,
        particleTypes: Int,
        allParticlesIntercommunicate: Bool,
        movementDirectionX: Double,
        movementDirectionY: Double,
        movementDirectionZ: Double,
        timeScale: Double,
        sphereSize: Double,
        spectrumOffset: Double,
        showOptimizationInfo: Bool,
        mlPlaybackRecipe: Int,
        mlPlaybackNormalizationMode: Int,
        playbackSurfaceMeshEnabled: Bool,
        playbackSurfaceSmoothing: Double,
        playbackFrontLayerVisible: Bool,
        playbackMiddleLayerVisible: Bool,
        playbackFinalLayerVisible: Bool,
        playbackFrontLayerSlot: Int,
        playbackMiddleLayerSlot: Int,
        playbackFinalLayerSlot: Int,
        playbackFrontLayerHorizontalOffset: Double,
        playbackMiddleLayerHorizontalOffset: Double,
        playbackFinalLayerHorizontalOffset: Double,
        playbackFrontLayerOffset: Double,
        playbackMiddleLayerOffset: Double,
        playbackFinalLayerOffset: Double,
        playbackTimeScale: Double,
        playbackInterpolationEnabled: Bool,
        showLeaderCommunicationLog: Bool,
        fixedGridSubdivisions: Int,
        fixedGridSubspaceCap: Int,
        fixedGridNeighborReadMode: String,
        protectLeaderFromUnload: Bool,
        assignedPhysicsModulePath: String?,
        assignedVisualModulePath: String?,
        assignedOptimizationModulePath: String?
    ) {
        self.particleCount = particleCount
        self.randomDistribution = randomDistribution
        self.particleTypes = particleTypes
        self.allParticlesIntercommunicate = allParticlesIntercommunicate
        self.movementDirectionX = movementDirectionX
        self.movementDirectionY = movementDirectionY
        self.movementDirectionZ = movementDirectionZ
        self.timeScale = timeScale
        self.sphereSize = sphereSize
        self.spectrumOffset = spectrumOffset
        self.showOptimizationInfo = showOptimizationInfo
        self.mlPlaybackRecipe = mlPlaybackRecipe
        self.mlPlaybackNormalizationMode = mlPlaybackNormalizationMode
        self.playbackSurfaceMeshEnabled = playbackSurfaceMeshEnabled
        self.playbackSurfaceSmoothing = playbackSurfaceSmoothing
        self.playbackFrontLayerVisible = playbackFrontLayerVisible
        self.playbackMiddleLayerVisible = playbackMiddleLayerVisible
        self.playbackFinalLayerVisible = playbackFinalLayerVisible
        self.playbackFrontLayerSlot = playbackFrontLayerSlot
        self.playbackMiddleLayerSlot = playbackMiddleLayerSlot
        self.playbackFinalLayerSlot = playbackFinalLayerSlot
        self.playbackFrontLayerHorizontalOffset = playbackFrontLayerHorizontalOffset
        self.playbackMiddleLayerHorizontalOffset = playbackMiddleLayerHorizontalOffset
        self.playbackFinalLayerHorizontalOffset = playbackFinalLayerHorizontalOffset
        self.playbackFrontLayerOffset = playbackFrontLayerOffset
        self.playbackMiddleLayerOffset = playbackMiddleLayerOffset
        self.playbackFinalLayerOffset = playbackFinalLayerOffset
        self.playbackTimeScale = playbackTimeScale
        self.playbackInterpolationEnabled = playbackInterpolationEnabled
        self.showLeaderCommunicationLog = showLeaderCommunicationLog
        self.fixedGridSubdivisions = fixedGridSubdivisions
        self.fixedGridSubspaceCap = fixedGridSubspaceCap
        self.fixedGridNeighborReadMode = fixedGridNeighborReadMode
        self.protectLeaderFromUnload = protectLeaderFromUnload
        self.assignedPhysicsModulePath = assignedPhysicsModulePath
        self.assignedVisualModulePath = assignedVisualModulePath
        self.assignedOptimizationModulePath = assignedOptimizationModulePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default

        particleCount = try container.decode(Int.self, forKey: .particleCount)
        randomDistribution = try container.decode(Bool.self, forKey: .randomDistribution)
        particleTypes = try container.decode(Int.self, forKey: .particleTypes)
        allParticlesIntercommunicate = try container.decode(Bool.self, forKey: .allParticlesIntercommunicate)
        movementDirectionX = try container.decode(Double.self, forKey: .movementDirectionX)
        movementDirectionY = try container.decode(Double.self, forKey: .movementDirectionY)
        movementDirectionZ = try container.decode(Double.self, forKey: .movementDirectionZ)
        timeScale = try container.decode(Double.self, forKey: .timeScale)
        sphereSize = try container.decode(Double.self, forKey: .sphereSize)
        spectrumOffset = try container.decode(Double.self, forKey: .spectrumOffset)
        showOptimizationInfo = try container.decode(Bool.self, forKey: .showOptimizationInfo)
        mlPlaybackRecipe = try container.decodeIfPresent(Int.self, forKey: .mlPlaybackRecipe)
            ?? fallback.mlPlaybackRecipe
        mlPlaybackNormalizationMode = try container.decodeIfPresent(Int.self, forKey: .mlPlaybackNormalizationMode)
            ?? fallback.mlPlaybackNormalizationMode
        playbackSurfaceMeshEnabled = try container.decodeIfPresent(Bool.self, forKey: .playbackSurfaceMeshEnabled)
            ?? fallback.playbackSurfaceMeshEnabled
        playbackSurfaceSmoothing = try container.decodeIfPresent(Double.self, forKey: .playbackSurfaceSmoothing)
            ?? fallback.playbackSurfaceSmoothing
        playbackFrontLayerVisible = try container.decodeIfPresent(Bool.self, forKey: .playbackFrontLayerVisible)
            ?? fallback.playbackFrontLayerVisible
        playbackMiddleLayerVisible = try container.decodeIfPresent(Bool.self, forKey: .playbackMiddleLayerVisible)
            ?? fallback.playbackMiddleLayerVisible
        playbackFinalLayerVisible = try container.decodeIfPresent(Bool.self, forKey: .playbackFinalLayerVisible)
            ?? fallback.playbackFinalLayerVisible
        playbackFrontLayerSlot = min(
            max(0, try container.decodeIfPresent(Int.self, forKey: .playbackFrontLayerSlot) ?? fallback.playbackFrontLayerSlot),
            4
        )
        playbackMiddleLayerSlot = min(
            max(0, try container.decodeIfPresent(Int.self, forKey: .playbackMiddleLayerSlot) ?? fallback.playbackMiddleLayerSlot),
            4
        )
        playbackFinalLayerSlot = min(
            max(0, try container.decodeIfPresent(Int.self, forKey: .playbackFinalLayerSlot) ?? fallback.playbackFinalLayerSlot),
            4
        )
        playbackFrontLayerHorizontalOffset = min(
            max(-1.5, try container.decodeIfPresent(Double.self, forKey: .playbackFrontLayerHorizontalOffset) ?? fallback.playbackFrontLayerHorizontalOffset),
            1.5
        )
        playbackMiddleLayerHorizontalOffset = min(
            max(-1.5, try container.decodeIfPresent(Double.self, forKey: .playbackMiddleLayerHorizontalOffset) ?? fallback.playbackMiddleLayerHorizontalOffset),
            1.5
        )
        playbackFinalLayerHorizontalOffset = min(
            max(-1.5, try container.decodeIfPresent(Double.self, forKey: .playbackFinalLayerHorizontalOffset) ?? fallback.playbackFinalLayerHorizontalOffset),
            1.5
        )
        playbackFrontLayerOffset = min(
            max(-1.5, try container.decodeIfPresent(Double.self, forKey: .playbackFrontLayerOffset) ?? fallback.playbackFrontLayerOffset),
            1.5
        )
        playbackMiddleLayerOffset = min(
            max(-1.5, try container.decodeIfPresent(Double.self, forKey: .playbackMiddleLayerOffset) ?? fallback.playbackMiddleLayerOffset),
            1.5
        )
        playbackFinalLayerOffset = min(
            max(-1.5, try container.decodeIfPresent(Double.self, forKey: .playbackFinalLayerOffset) ?? fallback.playbackFinalLayerOffset),
            1.5
        )
        playbackTimeScale = try container.decodeIfPresent(Double.self, forKey: .playbackTimeScale)
            ?? fallback.playbackTimeScale
        playbackInterpolationEnabled = try container.decodeIfPresent(Bool.self, forKey: .playbackInterpolationEnabled)
            ?? fallback.playbackInterpolationEnabled
        showLeaderCommunicationLog = try container.decode(Bool.self, forKey: .showLeaderCommunicationLog)
        fixedGridSubdivisions = try container.decodeIfPresent(Int.self, forKey: .fixedGridSubdivisions) ?? fallback.fixedGridSubdivisions
        fixedGridSubspaceCap = try container.decodeIfPresent(Int.self, forKey: .fixedGridSubspaceCap) ?? fallback.fixedGridSubspaceCap
        fixedGridNeighborReadMode = try container.decodeIfPresent(String.self, forKey: .fixedGridNeighborReadMode) ?? fallback.fixedGridNeighborReadMode
        protectLeaderFromUnload = try container.decode(Bool.self, forKey: .protectLeaderFromUnload)
        assignedPhysicsModulePath = try container.decodeIfPresent(String.self, forKey: .assignedPhysicsModulePath)
        assignedVisualModulePath = try container.decodeIfPresent(String.self, forKey: .assignedVisualModulePath)
        assignedOptimizationModulePath = try container.decodeIfPresent(String.self, forKey: .assignedOptimizationModulePath)
    }

    var editorState: SimulationEditorState {
        SimulationEditorState(
            physicsState: physicsState,
            visualState: visualState,
            optimizationState: optimizationState,
            playbackSettings: playbackSettings,
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
            showOptimizationInfo: showOptimizationInfo,
            mlPlaybackRecipe: MLPlaybackVisualRecipe(rawValue: mlPlaybackRecipe) ?? .typeSpectrum,
            mlPlaybackNormalizationMode: MLPlaybackNormalizationMode(rawValue: mlPlaybackNormalizationMode) ?? .global,
            playbackSurfaceMeshEnabled: playbackSurfaceMeshEnabled,
            playbackSurfaceSmoothing: min(max(0, playbackSurfaceSmoothing), 1),
            playbackFrontLayerVisible: playbackFrontLayerVisible,
            playbackMiddleLayerVisible: playbackMiddleLayerVisible,
            playbackFinalLayerVisible: playbackFinalLayerVisible,
            playbackFrontLayerSlot: playbackFrontLayerSlot,
            playbackMiddleLayerSlot: playbackMiddleLayerSlot,
            playbackFinalLayerSlot: playbackFinalLayerSlot,
            playbackFrontLayerHorizontalOffset: playbackFrontLayerHorizontalOffset,
            playbackMiddleLayerHorizontalOffset: playbackMiddleLayerHorizontalOffset,
            playbackFinalLayerHorizontalOffset: playbackFinalLayerHorizontalOffset,
            playbackFrontLayerOffset: playbackFrontLayerOffset,
            playbackMiddleLayerOffset: playbackMiddleLayerOffset,
            playbackFinalLayerOffset: playbackFinalLayerOffset
        )
    }

    var optimizationState: OptimizationModuleState {
        OptimizationModuleState(
            showLeaderCommunicationLog: showLeaderCommunicationLog,
            fixedGridSubdivisions: fixedGridSubdivisions,
            fixedGridSubspaceCap: fixedGridSubspaceCap,
            fixedGridNeighborReadMode: FixedGridNeighborReadMode(rawValue: fixedGridNeighborReadMode) ?? .scratch
        )
    }

    var playbackSettings: PlaybackSettingsState {
        PlaybackSettingsState(
            interpolationEnabled: playbackInterpolationEnabled
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
        playbackSettings: PlaybackSettingsState,
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
            mlPlaybackRecipe: visualState.mlPlaybackRecipe.rawValue,
            mlPlaybackNormalizationMode: visualState.mlPlaybackNormalizationMode.rawValue,
            playbackSurfaceMeshEnabled: visualState.playbackSurfaceMeshEnabled,
            playbackSurfaceSmoothing: min(max(0, visualState.playbackSurfaceSmoothing), 1),
            playbackFrontLayerVisible: visualState.playbackFrontLayerVisible,
            playbackMiddleLayerVisible: visualState.playbackMiddleLayerVisible,
            playbackFinalLayerVisible: visualState.playbackFinalLayerVisible,
            playbackFrontLayerSlot: min(max(0, visualState.playbackFrontLayerSlot), 4),
            playbackMiddleLayerSlot: min(max(0, visualState.playbackMiddleLayerSlot), 4),
            playbackFinalLayerSlot: min(max(0, visualState.playbackFinalLayerSlot), 4),
            playbackFrontLayerHorizontalOffset: min(max(-1.5, visualState.playbackFrontLayerHorizontalOffset), 1.5),
            playbackMiddleLayerHorizontalOffset: min(max(-1.5, visualState.playbackMiddleLayerHorizontalOffset), 1.5),
            playbackFinalLayerHorizontalOffset: min(max(-1.5, visualState.playbackFinalLayerHorizontalOffset), 1.5),
            playbackFrontLayerOffset: min(max(-1.5, visualState.playbackFrontLayerOffset), 1.5),
            playbackMiddleLayerOffset: min(max(-1.5, visualState.playbackMiddleLayerOffset), 1.5),
            playbackFinalLayerOffset: min(max(-1.5, visualState.playbackFinalLayerOffset), 1.5),
            playbackTimeScale: max(0.01, physicsState.timeScale),
            playbackInterpolationEnabled: playbackSettings.interpolationEnabled,
            showLeaderCommunicationLog: optimizationState.showLeaderCommunicationLog,
            fixedGridSubdivisions: optimizationState.fixedGridSubdivisions,
            fixedGridSubspaceCap: optimizationState.fixedGridSubspaceCap,
            fixedGridNeighborReadMode: optimizationState.fixedGridNeighborReadMode.rawValue,
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
            playbackSettings: editorState.playbackSettings,
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

    func setEditorState(_ nextState: SimulationEditorState) {
        let previous = editorState
        editorState = nextState
        persist()
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_editor_state",
            details: [
                "from": InteractionSnapshotFormat.viewport(
                    SimulationConfigurationDerivation.simulationState(
                        transportState: .stopped,
                        editorState: previous,
                        availableFiles: []
                    )
                ),
                "to": InteractionSnapshotFormat.viewport(
                    SimulationConfigurationDerivation.simulationState(
                        transportState: .stopped,
                        editorState: nextState,
                        availableFiles: []
                    )
                ),
            ]
        )
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

    func setPlaybackSettings(_ nextState: PlaybackSettingsState) {
        let previous = editorState.playbackSettings
        updateEditorState {
            $0.playbackSettings = nextState
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_playback_settings",
            details: [
                "from": "interpolation=\(previous.interpolationEnabled)",
                "to": "interpolation=\(nextState.interpolationEnabled)",
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
            guard let storedPath = nextAssignments[kind.rawValue] else {
                continue
            }

            guard let resolvedFile = SimulationConfigurationDerivation.resolvedAssignedModuleFile(
                for: kind,
                assignedPath: storedPath,
                availableFiles: availableFiles
            ) else {
                nextAssignments.removeValue(forKey: kind.rawValue)
                didChange = true
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
