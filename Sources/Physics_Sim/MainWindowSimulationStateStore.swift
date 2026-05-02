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
    var fixedGridSubdivisions: Int
    var fixedGridSubspaceCap: Int
    var fixedGridNeighborReadMode: FixedGridNeighborReadMode
    var protectLeaderFromUnload: Bool
    var assignedPhysicsModuleID: String?
    var assignedVisualModuleID: String?
    var assignedOptimizationModuleID: String?

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
        case showLeaderCommunicationLog
        case fixedGridSubdivisions
        case fixedGridSubspaceCap
        case fixedGridNeighborReadMode
        case protectLeaderFromUnload
        case assignedPhysicsModuleID
        case assignedVisualModuleID
        case assignedOptimizationModuleID
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
        showLeaderCommunicationLog: false,
        fixedGridSubdivisions: FixedGridOptimizationModuleRuntime.defaultSubdivisions,
        fixedGridSubspaceCap: 2,
        fixedGridNeighborReadMode: .scratch,
        protectLeaderFromUnload: true,
        assignedPhysicsModuleID: nil,
        assignedVisualModuleID: nil,
        assignedOptimizationModuleID: nil
    )

    var editorState: SimulationEditorState {
        SimulationEditorState(
            physicsState: physicsState,
            visualState: visualState,
            optimizationState: optimizationState,
            debugSettings: debugSettings,
            assignedModuleIDs: assignedModules
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
            fixedGridSubdivisions: fixedGridSubdivisions,
            fixedGridSubspaceCap: fixedGridSubspaceCap,
            fixedGridNeighborReadMode: fixedGridNeighborReadMode
        )
    }

    var debugSettings: DebugSettingsState {
        DebugSettingsState(protectLeaderFromUnload: protectLeaderFromUnload)
    }

    var assignedModules: [String: String] {
        var result: [String: String] = [:]
        if let assignedPhysicsModuleID { result[Self.physicsModuleKey] = assignedPhysicsModuleID }
        if let assignedVisualModuleID { result[Self.visualModuleKey] = assignedVisualModuleID }
        if let assignedOptimizationModuleID { result[Self.optimizationModuleKey] = assignedOptimizationModuleID }
        return result
    }

    static func from(
        physicsState: PhysicsModuleState,
        visualState: VisualModuleState,
        optimizationState: OptimizationModuleState,
        debugSettings: DebugSettingsState,
        assignedModuleIDs: [String: String]
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
            fixedGridSubdivisions: optimizationState.fixedGridSubdivisions,
            fixedGridSubspaceCap: optimizationState.fixedGridSubspaceCap,
            fixedGridNeighborReadMode: optimizationState.fixedGridNeighborReadMode,
            protectLeaderFromUnload: debugSettings.protectLeaderFromUnload,
            assignedPhysicsModuleID: assignedModuleIDs[Self.physicsModuleKey],
            assignedVisualModuleID: assignedModuleIDs[Self.visualModuleKey],
            assignedOptimizationModuleID: assignedModuleIDs[Self.optimizationModuleKey]
        )
    }

    static func from(editorState: SimulationEditorState) -> MainWindowSimulationStateSnapshot {
        from(
            physicsState: editorState.physicsState,
            visualState: editorState.visualState,
            optimizationState: editorState.optimizationState,
            debugSettings: editorState.debugSettings,
            assignedModuleIDs: editorState.assignedModuleIDs
        )
    }

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
        showLeaderCommunicationLog: Bool,
        fixedGridSubdivisions: Int,
        fixedGridSubspaceCap: Int,
        fixedGridNeighborReadMode: FixedGridNeighborReadMode,
        protectLeaderFromUnload: Bool,
        assignedPhysicsModuleID: String?,
        assignedVisualModuleID: String?,
        assignedOptimizationModuleID: String?
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
        self.showLeaderCommunicationLog = showLeaderCommunicationLog
        self.fixedGridSubdivisions = fixedGridSubdivisions
        self.fixedGridSubspaceCap = fixedGridSubspaceCap
        self.fixedGridNeighborReadMode = fixedGridNeighborReadMode
        self.protectLeaderFromUnload = protectLeaderFromUnload
        self.assignedPhysicsModuleID = assignedPhysicsModuleID
        self.assignedVisualModuleID = assignedVisualModuleID
        self.assignedOptimizationModuleID = assignedOptimizationModuleID
    }

    init(from decoder: Decoder) throws {
        let fallback = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        particleCount = try container.decodeIfPresent(Int.self, forKey: .particleCount) ?? fallback.particleCount
        randomDistribution = try container.decodeIfPresent(Bool.self, forKey: .randomDistribution) ?? fallback.randomDistribution
        particleTypes = try container.decodeIfPresent(Int.self, forKey: .particleTypes) ?? fallback.particleTypes
        allParticlesIntercommunicate = try container.decodeIfPresent(Bool.self, forKey: .allParticlesIntercommunicate) ?? fallback.allParticlesIntercommunicate
        movementDirectionX = try container.decodeIfPresent(Double.self, forKey: .movementDirectionX) ?? fallback.movementDirectionX
        movementDirectionY = try container.decodeIfPresent(Double.self, forKey: .movementDirectionY) ?? fallback.movementDirectionY
        movementDirectionZ = try container.decodeIfPresent(Double.self, forKey: .movementDirectionZ) ?? fallback.movementDirectionZ
        timeScale = try container.decodeIfPresent(Double.self, forKey: .timeScale) ?? fallback.timeScale
        sphereSize = try container.decodeIfPresent(Double.self, forKey: .sphereSize) ?? fallback.sphereSize
        spectrumOffset = try container.decodeIfPresent(Double.self, forKey: .spectrumOffset) ?? fallback.spectrumOffset
        showOptimizationInfo = try container.decodeIfPresent(Bool.self, forKey: .showOptimizationInfo) ?? fallback.showOptimizationInfo
        showLeaderCommunicationLog = try container.decodeIfPresent(Bool.self, forKey: .showLeaderCommunicationLog) ?? fallback.showLeaderCommunicationLog
        fixedGridSubdivisions = try container.decodeIfPresent(Int.self, forKey: .fixedGridSubdivisions) ?? fallback.fixedGridSubdivisions
        fixedGridSubspaceCap = try container.decodeIfPresent(Int.self, forKey: .fixedGridSubspaceCap) ?? fallback.fixedGridSubspaceCap
        fixedGridNeighborReadMode = try container.decodeIfPresent(FixedGridNeighborReadMode.self, forKey: .fixedGridNeighborReadMode) ?? fallback.fixedGridNeighborReadMode
        protectLeaderFromUnload = try container.decodeIfPresent(Bool.self, forKey: .protectLeaderFromUnload) ?? fallback.protectLeaderFromUnload
        assignedPhysicsModuleID = try container.decodeIfPresent(String.self, forKey: .assignedPhysicsModuleID)
            ?? container.decodeIfPresent(String.self, forKey: .assignedPhysicsModulePath)
        assignedVisualModuleID = try container.decodeIfPresent(String.self, forKey: .assignedVisualModuleID)
            ?? container.decodeIfPresent(String.self, forKey: .assignedVisualModulePath)
        assignedOptimizationModuleID = try container.decodeIfPresent(String.self, forKey: .assignedOptimizationModuleID)
            ?? container.decodeIfPresent(String.self, forKey: .assignedOptimizationModulePath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(particleCount, forKey: .particleCount)
        try container.encode(randomDistribution, forKey: .randomDistribution)
        try container.encode(particleTypes, forKey: .particleTypes)
        try container.encode(allParticlesIntercommunicate, forKey: .allParticlesIntercommunicate)
        try container.encode(movementDirectionX, forKey: .movementDirectionX)
        try container.encode(movementDirectionY, forKey: .movementDirectionY)
        try container.encode(movementDirectionZ, forKey: .movementDirectionZ)
        try container.encode(timeScale, forKey: .timeScale)
        try container.encode(sphereSize, forKey: .sphereSize)
        try container.encode(spectrumOffset, forKey: .spectrumOffset)
        try container.encode(showOptimizationInfo, forKey: .showOptimizationInfo)
        try container.encode(showLeaderCommunicationLog, forKey: .showLeaderCommunicationLog)
        try container.encode(fixedGridSubdivisions, forKey: .fixedGridSubdivisions)
        try container.encode(fixedGridSubspaceCap, forKey: .fixedGridSubspaceCap)
        try container.encode(fixedGridNeighborReadMode, forKey: .fixedGridNeighborReadMode)
        try container.encode(protectLeaderFromUnload, forKey: .protectLeaderFromUnload)
        try container.encodeIfPresent(assignedPhysicsModuleID, forKey: .assignedPhysicsModuleID)
        try container.encodeIfPresent(assignedVisualModuleID, forKey: .assignedVisualModuleID)
        try container.encodeIfPresent(assignedOptimizationModuleID, forKey: .assignedOptimizationModuleID)
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

    func setAssignedModuleID(_ moduleID: String?, for kind: ModuleKind) {
        let previous = editorState.assignedModuleIDs[kind.rawValue]
        updateEditorState {
            if let moduleID {
                $0.assignedModuleIDs[kind.rawValue] = moduleID
            } else {
                $0.assignedModuleIDs.removeValue(forKey: kind.rawValue)
            }
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_assigned_module_id",
            details: [
                "kind": kind.rawValue,
                "from": InteractionSnapshotFormat.assignedModuleID(previous),
                "to": InteractionSnapshotFormat.assignedModuleID(moduleID),
            ]
        )
    }

    func assignedModuleID(for kind: ModuleKind) -> String? {
        editorState.assignedModuleIDs[kind.rawValue]
    }

    func normalizeAssignedModuleIDs(availableBundles: [ModuleBundle]) {
        var nextAssignments = editorState.assignedModuleIDs
        var didChange = false

        for kind in ModuleKind.allCases {
            guard let storedID = nextAssignments[kind.rawValue],
                  let resolvedBundle = SimulationConfigurationDerivation.resolvedAssignedModuleBundle(
                    for: kind,
                    assignedModuleID: storedID,
                    availableBundles: availableBundles
                  ) else {
                continue
            }

            if resolvedBundle.id != storedID {
                nextAssignments[kind.rawValue] = resolvedBundle.id
                didChange = true
            }
        }

        guard didChange else { return }
        updateEditorState {
            $0.assignedModuleIDs = nextAssignments
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
