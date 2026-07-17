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
    var playbackLooping: Bool
    var protectLeaderFromUnload: Bool
    var moduleSettings: [String: [String: ModuleSettingValue]]
    var assignedPhysicsModuleID: String?
    var assignedVisualModuleID: String?
    var assignedOptimizationModuleID: String?
    var selectedTrinityID: String?
    var trinitySettings: [String: TrinitySettingsSnapshot]

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
        case playbackLooping
        case protectLeaderFromUnload
        case moduleSettings
        case assignedPhysicsModuleID
        case assignedVisualModuleID
        case assignedOptimizationModuleID
        case selectedTrinityID
        case trinitySettings
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
        playbackLooping: true,
        protectLeaderFromUnload: true,
        moduleSettings: [:],
        assignedPhysicsModuleID: nil,
        assignedVisualModuleID: nil,
        assignedOptimizationModuleID: nil,
        selectedTrinityID: TrinityCatalog.defaultRealtime.id,
        trinitySettings: [:]
    )

    var editorState: SimulationEditorState {
        SimulationEditorState(
            physicsState: physicsState,
            visualState: visualState,
            optimizationState: optimizationState,
            playbackState: playbackState,
            debugSettings: debugSettings,
            moduleSettings: moduleSettings,
            assignedModuleIDs: assignedModules,
            selectedTrinityID: selectedTrinityID,
            trinitySettings: trinitySettings
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

    var playbackState: PlaybackModuleState {
        PlaybackModuleState(looping: playbackLooping)
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
        playbackState: PlaybackModuleState,
        debugSettings: DebugSettingsState,
        moduleSettings: [String: [String: ModuleSettingValue]],
        assignedModuleIDs: [String: String],
        selectedTrinityID: String?,
        trinitySettings: [String: TrinitySettingsSnapshot]
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
            playbackLooping: playbackState.looping,
            protectLeaderFromUnload: debugSettings.protectLeaderFromUnload,
            moduleSettings: moduleSettings,
            assignedPhysicsModuleID: assignedModuleIDs[Self.physicsModuleKey],
            assignedVisualModuleID: assignedModuleIDs[Self.visualModuleKey],
            assignedOptimizationModuleID: assignedModuleIDs[Self.optimizationModuleKey],
            selectedTrinityID: selectedTrinityID,
            trinitySettings: trinitySettings
        )
    }

    static func from(editorState: SimulationEditorState) -> MainWindowSimulationStateSnapshot {
        from(
            physicsState: editorState.physicsState,
            visualState: editorState.visualState,
            optimizationState: editorState.optimizationState,
            playbackState: editorState.playbackState,
            debugSettings: editorState.debugSettings,
            moduleSettings: editorState.moduleSettings,
            assignedModuleIDs: editorState.assignedModuleIDs,
            selectedTrinityID: editorState.selectedTrinityID,
            trinitySettings: editorState.trinitySettings
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
        playbackLooping: Bool,
        protectLeaderFromUnload: Bool,
        moduleSettings: [String: [String: ModuleSettingValue]],
        assignedPhysicsModuleID: String?,
        assignedVisualModuleID: String?,
        assignedOptimizationModuleID: String?,
        selectedTrinityID: String?,
        trinitySettings: [String: TrinitySettingsSnapshot]
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
        self.playbackLooping = playbackLooping
        self.protectLeaderFromUnload = protectLeaderFromUnload
        self.moduleSettings = moduleSettings
        self.assignedPhysicsModuleID = assignedPhysicsModuleID
        self.assignedVisualModuleID = assignedVisualModuleID
        self.assignedOptimizationModuleID = assignedOptimizationModuleID
        self.selectedTrinityID = selectedTrinityID
        self.trinitySettings = trinitySettings
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
        playbackLooping = try container.decodeIfPresent(Bool.self, forKey: .playbackLooping) ?? fallback.playbackLooping
        protectLeaderFromUnload = try container.decodeIfPresent(Bool.self, forKey: .protectLeaderFromUnload) ?? fallback.protectLeaderFromUnload
        moduleSettings = try container.decodeIfPresent([String: [String: ModuleSettingValue]].self, forKey: .moduleSettings)
            ?? fallback.moduleSettings
        assignedPhysicsModuleID = try container.decodeIfPresent(String.self, forKey: .assignedPhysicsModuleID)
            ?? container.decodeIfPresent(String.self, forKey: .assignedPhysicsModulePath)
        assignedVisualModuleID = try container.decodeIfPresent(String.self, forKey: .assignedVisualModuleID)
            ?? container.decodeIfPresent(String.self, forKey: .assignedVisualModulePath)
        assignedOptimizationModuleID = try container.decodeIfPresent(String.self, forKey: .assignedOptimizationModuleID)
            ?? container.decodeIfPresent(String.self, forKey: .assignedOptimizationModulePath)
        selectedTrinityID = try container.decodeIfPresent(String.self, forKey: .selectedTrinityID)
            ?? fallback.selectedTrinityID
        trinitySettings = try container.decodeIfPresent([String: TrinitySettingsSnapshot].self, forKey: .trinitySettings)
            ?? fallback.trinitySettings
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
        try container.encode(playbackLooping, forKey: .playbackLooping)
        try container.encode(protectLeaderFromUnload, forKey: .protectLeaderFromUnload)
        try container.encode(moduleSettings, forKey: .moduleSettings)
        try container.encodeIfPresent(assignedPhysicsModuleID, forKey: .assignedPhysicsModuleID)
        try container.encodeIfPresent(assignedVisualModuleID, forKey: .assignedVisualModuleID)
        try container.encodeIfPresent(assignedOptimizationModuleID, forKey: .assignedOptimizationModuleID)
        try container.encodeIfPresent(selectedTrinityID, forKey: .selectedTrinityID)
        try container.encode(trinitySettings, forKey: .trinitySettings)
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
        var normalizedState = editorState
        refreshSelectedTrinity(in: &normalizedState)
        if normalizedState != editorState {
            editorState = normalizedState
            persist()
        }
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

    func setPlaybackState(_ nextState: PlaybackModuleState) {
        let previous = editorState.playbackState
        updateEditorState {
            $0.playbackState = nextState
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_playback_state",
            details: [
                "from": "looping=\(previous.looping)",
                "to": "looping=\(nextState.looping)",
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

    func moduleSetting(
        moduleID: String,
        settingID: String,
        defaultValue: ModuleSettingValue
    ) -> ModuleSettingValue {
        editorState.moduleSettings[moduleID]?[settingID] ?? defaultValue
    }

    func setModuleSetting(
        moduleID: String,
        settingID: String,
        value: ModuleSettingValue
    ) {
        let previous = editorState.moduleSettings[moduleID]?[settingID]
        updateEditorState {
            var moduleValues = $0.moduleSettings[moduleID] ?? [:]
            moduleValues[settingID] = value
            $0.moduleSettings[moduleID] = moduleValues
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_module_setting",
            details: [
                "moduleID": moduleID,
                "settingID": settingID,
                "from": String(describing: previous),
                "to": String(describing: value),
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
            $0.selectedTrinityID = nil
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

    func setSelectedTrinity(_ trinity: TrinityDefinition) {
        let previous = editorState.selectedTrinityID
        updateEditorState {
            persistCurrentTrinitySettings(in: &$0)
            let restoredSettings = $0.trinitySettings[trinity.id] ?? trinity.defaultSettings
            $0.physicsState = restoredSettings.physicsState
            $0.visualState = restoredSettings.visualState
            $0.optimizationState = restoredSettings.optimizationState
            $0.playbackState = restoredSettings.playbackState
            $0.debugSettings = restoredSettings.debugSettings
            $0.moduleSettings = restoredSettings.moduleSettings
            $0.assignedModuleIDs = trinity.assignedModuleIDs
            $0.selectedTrinityID = trinity.id
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.set_selected_trinity",
            details: [
                "from": previous ?? "custom",
                "to": trinity.id,
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
        refreshSelectedTrinity(in: &nextEditorState)
        editorState = nextEditorState
        persist()
    }

    private func refreshSelectedTrinity(in state: inout SimulationEditorState) {
        guard let matchingTrinity = TrinityCatalog.all.first(where: { trinity in
            normalizedAssignedModuleIDs(state.assignedModuleIDs) == normalizedAssignedModuleIDs(trinity.assignedModuleIDs)
        }) else {
            state.selectedTrinityID = nil
            return
        }

        state.selectedTrinityID = matchingTrinity.id
        state.trinitySettings[matchingTrinity.id] = TrinitySettingsSnapshot(
            physicsState: state.physicsState,
            visualState: state.visualState,
            optimizationState: state.optimizationState,
            playbackState: state.playbackState,
            debugSettings: state.debugSettings,
            moduleSettings: state.moduleSettings
        )
    }

    private func persistCurrentTrinitySettings(in state: inout SimulationEditorState) {
        guard let trinityID = state.selectedTrinityID,
              TrinityCatalog.definition(id: trinityID) != nil else {
            return
        }
        state.trinitySettings[trinityID] = TrinitySettingsSnapshot(
            physicsState: state.physicsState,
            visualState: state.visualState,
            optimizationState: state.optimizationState,
            playbackState: state.playbackState,
            debugSettings: state.debugSettings,
            moduleSettings: state.moduleSettings
        )
    }

    private func normalizedAssignedModuleIDs(_ assignedModuleIDs: [String: String]) -> [String: String] {
        assignedModuleIDs.filter { !$0.value.isEmpty }
    }

    private func persist() {
        MainWindowSimulationStateStore.shared.save(.from(editorState: editorState))
    }
}
