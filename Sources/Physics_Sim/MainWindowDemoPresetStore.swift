import Foundation

enum DemoPlaybackPreset: String, CaseIterable, Codable, Identifiable {
    case naiveNSquared
    case subdividedGrid
    case machineLearningTrainingPlayback
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .naiveNSquared:
            return "Naive n^2"
        case .subdividedGrid:
            return "Subdivided Grid"
        case .machineLearningTrainingPlayback:
            return "Machine Learning Training Playback"
        case .custom:
            return "Custom"
        }
    }

    var isBuiltIn: Bool { self != .custom }
}

struct DemoPlaybackPresetEntry: Codable, Equatable, Sendable {
    var simulationState: MainWindowSimulationStateSnapshot
    var physicsModuleSettings: MainWindowPhysicsModuleSettingsSnapshot
}

struct MainWindowDemoPresetSnapshot: Codable, Equatable, Sendable {
    var activePreset: DemoPlaybackPreset = .custom
    var entriesByPresetID: [String: DemoPlaybackPresetEntry] = [:]
}

@MainActor
final class MainWindowDemoPresetStore: ObservableObject {
    static let shared = MainWindowDemoPresetStore()

    @Published private(set) var snapshot: MainWindowDemoPresetSnapshot

    private let store = CodableDefaultsStore<MainWindowDemoPresetSnapshot>(
        defaultsKey: "PhysicsSim.MainWindowDemoPresetStore.v1",
        queueLabel: "PhysicsSim.MainWindowDemoPresetStore"
    )
    private var isApplyingPreset = false

    init() {
        snapshot = store.load(fallback: MainWindowDemoPresetSnapshot())
    }

    var activePreset: DemoPlaybackPreset {
        snapshot.activePreset
    }

    func ensureSeeded(
        availableFiles: [ModuleFile],
        fallbackEditorState: SimulationEditorState,
        fallbackPhysicsSettings: MainWindowPhysicsModuleSettingsSnapshot
    ) {
        var nextSnapshot = snapshot
        var didChange = false

        for preset in DemoPlaybackPreset.allCases where preset.isBuiltIn {
            let seededEntry = seededEntry(
                for: preset,
                availableFiles: availableFiles,
                fallbackEditorState: fallbackEditorState,
                fallbackPhysicsSettings: fallbackPhysicsSettings
            )
            if let existingEntry = nextSnapshot.entriesByPresetID[preset.rawValue] {
                let repairedEntry = repairingMissingAssignments(
                    existingEntry,
                    seededEntry: seededEntry
                )
                if repairedEntry != existingEntry {
                    nextSnapshot.entriesByPresetID[preset.rawValue] = repairedEntry
                    didChange = true
                }
            } else {
                nextSnapshot.entriesByPresetID[preset.rawValue] = seededEntry
                didChange = true
            }
        }

        if didChange {
            snapshot = nextSnapshot
            store.save(nextSnapshot)
        }
    }

    func applyPreset(
        _ preset: DemoPlaybackPreset,
        editorSettingsStore: MainWindowEditorSettingsStore,
        physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    ) {
        guard preset.isBuiltIn, let entry = entry(for: preset) else { return }
        isApplyingPreset = true
        var nextSnapshot = snapshot
        nextSnapshot.activePreset = preset
        snapshot = nextSnapshot
        store.save(nextSnapshot)
        editorSettingsStore.setEditorState(entry.simulationState.editorState)
        physicsModuleSettingsStore.setSnapshot(entry.physicsModuleSettings)
        isApplyingPreset = false
    }

    func syncFromLiveState(
        editorState: SimulationEditorState,
        physicsModuleSettings: MainWindowPhysicsModuleSettingsSnapshot
    ) {
        guard !isApplyingPreset else { return }

        let liveSimulationState = MainWindowSimulationStateSnapshot.from(editorState: editorState)
        var nextSnapshot = snapshot

        switch nextSnapshot.activePreset {
        case .custom:
            return
        case .naiveNSquared, .subdividedGrid, .machineLearningTrainingPlayback:
            guard let currentEntry = nextSnapshot.entriesByPresetID[nextSnapshot.activePreset.rawValue] else {
                nextSnapshot.activePreset = .custom
                snapshot = nextSnapshot
                store.save(nextSnapshot)
                return
            }

            if assignmentsMatch(lhs: liveSimulationState, rhs: currentEntry.simulationState) {
                let nextEntry = DemoPlaybackPresetEntry(
                    simulationState: liveSimulationState,
                    physicsModuleSettings: physicsModuleSettings
                )
                if nextEntry != currentEntry {
                    nextSnapshot.entriesByPresetID[nextSnapshot.activePreset.rawValue] = nextEntry
                    snapshot = nextSnapshot
                    store.save(nextSnapshot)
                }
            } else {
                nextSnapshot.activePreset = .custom
                snapshot = nextSnapshot
                store.save(nextSnapshot)
            }
        }
    }

    private func entry(for preset: DemoPlaybackPreset) -> DemoPlaybackPresetEntry? {
        snapshot.entriesByPresetID[preset.rawValue]
    }

    private func seededEntry(
        for preset: DemoPlaybackPreset,
        availableFiles: [ModuleFile],
        fallbackEditorState: SimulationEditorState,
        fallbackPhysicsSettings: MainWindowPhysicsModuleSettingsSnapshot
    ) -> DemoPlaybackPresetEntry {
        var simulationState = MainWindowSimulationStateSnapshot.from(editorState: fallbackEditorState)

        switch preset {
        case .naiveNSquared:
            simulationState.assignedPhysicsModulePath = path(
                for: .physics,
                moduleName: TypeMatrixLocalPhysicsSettings.moduleName,
                availableFiles: availableFiles
            )
            simulationState.assignedVisualModulePath = path(
                for: .visual,
                moduleName: ModuleCatalog.defaultVisual.name,
                availableFiles: availableFiles
            )
            simulationState.assignedOptimizationModulePath = path(
                for: .optimization,
                moduleName: ModuleCatalog.defaultOptimization.name,
                availableFiles: availableFiles
            )
        case .subdividedGrid:
            simulationState.assignedPhysicsModulePath = path(
                for: .physics,
                moduleName: TypeMatrixLocalPhysicsSettings.moduleName,
                availableFiles: availableFiles
            )
            simulationState.assignedVisualModulePath = path(
                for: .visual,
                moduleName: ModuleCatalog.defaultVisual.name,
                availableFiles: availableFiles
            )
            simulationState.assignedOptimizationModulePath = path(
                for: .optimization,
                moduleName: FixedGridOptimizationModuleRuntime.moduleName,
                availableFiles: availableFiles
            )
        case .machineLearningTrainingPlayback:
            simulationState.assignedPhysicsModulePath = path(
                for: .physics,
                moduleName: MLPlaybackModuleFamily.physicsModuleName,
                availableFiles: availableFiles
            )
            simulationState.assignedVisualModulePath = path(
                for: .visual,
                moduleName: MLPlaybackModuleFamily.visualModuleName,
                availableFiles: availableFiles
            )
            simulationState.assignedOptimizationModulePath = path(
                for: .optimization,
                moduleName: MLPlaybackModuleFamily.optimizationModuleName,
                availableFiles: availableFiles
            )
        case .custom:
            break
        }

        return DemoPlaybackPresetEntry(
            simulationState: simulationState,
            physicsModuleSettings: fallbackPhysicsSettings
        )
    }

    private func path(
        for kind: ModuleKind,
        moduleName: String,
        availableFiles: [ModuleFile]
    ) -> String? {
        availableFiles.first {
            $0.kind == kind && $0.descriptor?.name == moduleName
        }?.url.path
    }

    private func assignmentsMatch(
        lhs: MainWindowSimulationStateSnapshot,
        rhs: MainWindowSimulationStateSnapshot
    ) -> Bool {
        lhs.assignedPhysicsModulePath == rhs.assignedPhysicsModulePath
            && lhs.assignedVisualModulePath == rhs.assignedVisualModulePath
            && lhs.assignedOptimizationModulePath == rhs.assignedOptimizationModulePath
    }

    private func repairingMissingAssignments(
        _ existingEntry: DemoPlaybackPresetEntry,
        seededEntry: DemoPlaybackPresetEntry
    ) -> DemoPlaybackPresetEntry {
        var repairedEntry = existingEntry
        if repairedEntry.simulationState.assignedPhysicsModulePath == nil {
            repairedEntry.simulationState.assignedPhysicsModulePath = seededEntry.simulationState.assignedPhysicsModulePath
        }
        if repairedEntry.simulationState.assignedVisualModulePath == nil {
            repairedEntry.simulationState.assignedVisualModulePath = seededEntry.simulationState.assignedVisualModulePath
        }
        if repairedEntry.simulationState.assignedOptimizationModulePath == nil {
            repairedEntry.simulationState.assignedOptimizationModulePath = seededEntry.simulationState.assignedOptimizationModulePath
        }
        return repairedEntry
    }
}
