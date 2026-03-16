import Combine
import Foundation

@MainActor
final class SimulationRuntimeConfigCoordinator: ObservableObject {
    @Published private(set) var transportState: SimulationTransportState
    @Published private(set) var simulationState: SimulationViewportState
    @Published private(set) var activeModules: ActiveModuleSet
    @Published private(set) var validationReport: RuntimeValidationReport

    private let session: SimulationSession
    private let editorSettingsStore: MainWindowEditorSettingsStore
    private let moduleCatalogStore: MainWindowModuleCatalogStore
    private var cancellables: Set<AnyCancellable> = []

    init(
        session: SimulationSession,
        editorSettingsStore: MainWindowEditorSettingsStore,
        moduleCatalogStore: MainWindowModuleCatalogStore,
        memoryBudgetPreset: MemoryBudgetPreset = .m1Pro
    ) {
        self.session = session
        self.editorSettingsStore = editorSettingsStore
        self.moduleCatalogStore = moduleCatalogStore

        let initialSimulationState = Self.makeSimulationState(
            transportState: .stopped,
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
        let initialActiveModules = Self.makeActiveModules(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
        self.transportState = .stopped
        self.simulationState = initialSimulationState
        self.activeModules = initialActiveModules
        self.validationReport = Self.makeValidationReport(
            editorState: editorSettingsStore.editorState,
            simulationState: initialSimulationState,
            activeModules: initialActiveModules,
            memoryBudgetPreset: memoryBudgetPreset
        )

        editorSettingsStore.$editorState
            .sink { [weak self] editorState in
                self?.recomputeAndApply(
                    editorState: editorState,
                    availableFiles: self?.moduleCatalogStore.availableFiles ?? []
                )
            }
            .store(in: &cancellables)

        moduleCatalogStore.$availableFiles
            .sink { [weak self] availableFiles in
                guard let self else { return }
                self.recomputeAndApply(
                    editorState: self.editorSettingsStore.editorState,
                    availableFiles: availableFiles
                )
            }
            .store(in: &cancellables)

        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
    }

    func refreshModules() {
        moduleCatalogStore.refresh()
    }

    func refreshDerivedState() {
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
    }

    func startSimulation() {
        guard validationReport.canStart else { return }
        InteractionSnapshotRecorder.shared.record(event: "ui.start_simulation")
        transportState = .running
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
    }

    func togglePausePlay() {
        let previous = transportState
        switch transportState {
        case .stopped:
            return
        case .running:
            transportState = .paused
        case .paused:
            guard validationReport.canStart else { return }
            transportState = .running
        }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.toggle_pause_play",
            details: [
                "from": previous.rawValue,
                "to": transportState.rawValue,
            ]
        )
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
    }

    func stopSimulation() {
        guard transportState != .stopped else { return }
        InteractionSnapshotRecorder.shared.record(
            event: "ui.stop_simulation",
            details: ["from": transportState.rawValue]
        )
        transportState = .stopped
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
    }

    private func recomputeAndApply(
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) {
        let nextSimulationState = Self.makeSimulationState(
            transportState: transportState,
            editorState: editorState,
            availableFiles: availableFiles
        )
        let nextActiveModules = Self.makeActiveModules(
            editorState: editorState,
            availableFiles: availableFiles
        )
        let nextValidationReport = Self.makeValidationReport(
            editorState: editorState,
            simulationState: nextSimulationState,
            activeModules: nextActiveModules,
            memoryBudgetPreset: currentMemoryBudgetPreset
        )

        simulationState = nextSimulationState
        activeModules = nextActiveModules
        validationReport = nextValidationReport
        InteractionSnapshotRecorder.shared.record(
            event: "coordinator.recompute_and_apply",
            details: [
                "transport": transportState.rawValue,
                "simulationState": InteractionSnapshotFormat.viewport(nextSimulationState),
                "activeModules": InteractionSnapshotFormat.activeModules(nextActiveModules),
                "validationIssue": nextValidationReport.issue ?? "<nil>",
            ]
        )
        applyToSession(
            simulationState: nextSimulationState,
            activeModules: nextActiveModules
        )
    }

    private func applyToSession(
        simulationState: SimulationViewportState,
        activeModules: ActiveModuleSet
    ) {
        session.updateSimulationState(simulationState)
        do {
            try session.updateActiveModules(activeModules)
        } catch {
            // Leave validation/reporting to the published state. Avoid turning a bad config into a UI-side crash path.
        }
    }

    private var currentMemoryBudgetPreset: MemoryBudgetPreset {
        ProgramSettingsStore.memoryBudgetPreset
    }

    private static func makeSimulationState(
        transportState: SimulationTransportState,
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> SimulationViewportState {
        SimulationViewportState(
            transportState: transportState,
            particleCount: editorState.physicsState.particleCount,
            randomDistribution: editorState.physicsState.randomDistribution,
            particleTypes: editorState.physicsState.particleTypes,
            movementDirection: SIMD3<Float>(
                Float(editorState.physicsState.movementDirection.x),
                Float(editorState.physicsState.movementDirection.y),
                Float(editorState.physicsState.movementDirection.z)
            ),
            timeScale: Float(editorState.physicsState.timeScale),
            sphereSize: Float(editorState.visualState.sphereSize),
            spectrumOffset: Float(editorState.visualState.spectrumOffset),
            showOptimizationInfo: makeResolvedVisualSupportsOptimizationDebug(
                editorState: editorState,
                availableFiles: availableFiles
            ) && editorState.visualState.showOptimizationInfo,
            optimizationBlockingMode: editorState.optimizationState.blockingMode
        )
    }

    private static func makeActiveModules(
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> ActiveModuleSet {
        ActiveModuleSet(
            physics: resolveModule(for: .physics, editorState: editorState, availableFiles: availableFiles),
            visual: resolveModule(for: .visual, editorState: editorState, availableFiles: availableFiles),
            optimization: resolveModule(for: .optimization, editorState: editorState, availableFiles: availableFiles)
        )
    }

    private static func makeValidationReport(
        editorState: SimulationEditorState,
        simulationState: SimulationViewportState,
        activeModules: ActiveModuleSet,
        memoryBudgetPreset: MemoryBudgetPreset
    ) -> RuntimeValidationReport {
        let projectedBytes = projectedMemoryBytes(editorState: editorState)

        if let issue = ModuleCompatibility.incompatibilityReason(for: activeModules, state: simulationState) {
            return RuntimeValidationReport(issue: issue, projectedBytes: projectedBytes)
        }

        if editorState.optimizationState.showLeaderCommunicationLog,
           activeModules.optimization.name != ModuleCatalog.defaultOptimization.name {
            return RuntimeValidationReport(
                issue: "Leader communication log is only available with \(ModuleCatalog.defaultOptimization.name).",
                projectedBytes: projectedBytes
            )
        }

        if projectedBytes > memoryBudgetPreset.budgetBytes {
            return RuntimeValidationReport(
                issue: "Projected simulation memory exceeds the \(memoryBudgetPreset.title) budget.",
                projectedBytes: projectedBytes
            )
        }

        return RuntimeValidationReport(issue: nil, projectedBytes: projectedBytes)
    }

    private static func projectedMemoryBytes(editorState: SimulationEditorState) -> UInt64 {
        let particleCount = max(1, editorState.physicsState.particleCount)
        let baseParticleStride = 40
        let visualStride = 16
        let optimizationStride = 16
        let typeBudget = 32 * 32
        let debugBudget = editorState.optimizationState.showLeaderCommunicationLog ? 8 * 1024 * 1024 : 0
        let reserved = particleCount * (baseParticleStride + visualStride + optimizationStride) + typeBudget + debugBudget
        return UInt64(reserved)
    }

    private static func makeResolvedVisualSupportsOptimizationDebug(
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> Bool {
        resolveModule(for: .visual, editorState: editorState, availableFiles: availableFiles).acceptsOptimizationDebugInfo
            && resolveModule(for: .optimization, editorState: editorState, availableFiles: availableFiles).name == ModuleCatalog.defaultOptimization.name
    }

    private static func resolveModule(
        for kind: ModuleKind,
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> ModuleDescriptor {
        guard let path = editorState.assignedModulePaths[kind.rawValue] else {
            return ModuleCatalog.fallback(for: kind.rawValue)
        }
        let assignedURL = URL(fileURLWithPath: path)
        guard let file = availableFiles.first(where: { $0.url == assignedURL }),
              let descriptor = file.descriptor else {
            return ModuleCatalog.fallback(for: kind.rawValue)
        }
        return descriptor
    }
}
