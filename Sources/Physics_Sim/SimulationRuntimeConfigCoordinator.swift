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
    private let physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    private let moduleCatalogStore: MainWindowModuleCatalogStore
    private var cancellables: Set<AnyCancellable> = []

    init(
        session: SimulationSession,
        editorSettingsStore: MainWindowEditorSettingsStore,
        physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore,
        moduleCatalogStore: MainWindowModuleCatalogStore
    ) {
        self.session = session
        self.editorSettingsStore = editorSettingsStore
        self.physicsModuleSettingsStore = physicsModuleSettingsStore
        self.moduleCatalogStore = moduleCatalogStore

        let initialSimulationState = SimulationConfigurationDerivation.simulationState(
            transportState: .stopped,
            editorState: editorSettingsStore.editorState,
            availableBundles: moduleCatalogStore.availableBundles
        )
        let initialActiveModules = SimulationConfigurationDerivation.activeModules(
            editorState: editorSettingsStore.editorState,
            availableBundles: moduleCatalogStore.availableBundles
        )
        self.transportState = .stopped
        self.simulationState = initialSimulationState
        self.activeModules = initialActiveModules
        self.validationReport = SimulationConfigurationDerivation.validationReport(
            editorState: editorSettingsStore.editorState,
            transportState: .stopped,
            availableBundles: moduleCatalogStore.availableBundles
        )

        editorSettingsStore.$editorState
            .sink { [weak self] editorState in
                self?.recomputeAndApply(
                    editorState: editorState,
                    availableBundles: self?.moduleCatalogStore.availableBundles ?? []
                )
            }
            .store(in: &cancellables)

        moduleCatalogStore.$availableBundles
            .sink { [weak self] availableBundles in
                guard let self else { return }
                self.editorSettingsStore.normalizeAssignedModuleIDs(availableBundles: availableBundles)
                self.recomputeAndApply(
                    editorState: self.editorSettingsStore.editorState,
                    availableBundles: availableBundles
                )
            }
            .store(in: &cancellables)

        physicsModuleSettingsStore.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.session.updateTypeMatrixLocalSettings(
                    self.physicsModuleSettingsStore.typeMatrixLocalSettings(from: snapshot)
                )
            }
            .store(in: &cancellables)

        editorSettingsStore.normalizeAssignedModuleIDs(availableBundles: moduleCatalogStore.availableBundles)
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableBundles: moduleCatalogStore.availableBundles
        )
        session.updateTypeMatrixLocalSettings(physicsModuleSettingsStore.typeMatrixLocalSettings())
    }

    func refreshModules() {
        moduleCatalogStore.refresh()
    }

    func refreshDerivedState() {
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableBundles: moduleCatalogStore.availableBundles
        )
    }

    func startSimulation() {
        guard validationReport.canStart else { return }
        InteractionSnapshotRecorder.shared.record(event: "ui.start_simulation")
        transportState = .running
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableBundles: moduleCatalogStore.availableBundles
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
            availableBundles: moduleCatalogStore.availableBundles
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
            availableBundles: moduleCatalogStore.availableBundles
        )
    }

    private func recomputeAndApply(
        editorState: SimulationEditorState,
        availableBundles: [ModuleBundle]
    ) {
        let nextSimulationState = SimulationConfigurationDerivation.simulationState(
            transportState: transportState,
            editorState: editorState,
            availableBundles: availableBundles
        )
        let nextActiveModules = SimulationConfigurationDerivation.activeModules(
            editorState: editorState,
            availableBundles: availableBundles
        )
        let nextValidationReport = SimulationConfigurationDerivation.validationReport(
            editorState: editorState,
            transportState: transportState,
            availableBundles: availableBundles
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
        guard nextValidationReport.canStart else { return }
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
}
