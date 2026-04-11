import Combine
import Foundation

@MainActor
final class SimulationRuntimeConfigCoordinator: ObservableObject {
    @Published private(set) var transportState: SimulationTransportState
    @Published private(set) var simulationState: SimulationViewportState
    @Published private(set) var activeModules: ActiveModuleSet
    @Published private(set) var validationReport: RuntimeValidationReport
    @Published private(set) var playbackTimelineSnapshot: PlaybackTimelineSnapshot

    private let session: SimulationSession
    private let editorSettingsStore: MainWindowEditorSettingsStore
    private let physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    private let moduleCatalogStore: MainWindowModuleCatalogStore
    private var cancellables: Set<AnyCancellable> = []
    private var playbackScrubShouldResume = false

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
            availableFiles: moduleCatalogStore.availableFiles
        )
        let initialActiveModules = SimulationConfigurationDerivation.activeModules(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
        self.transportState = .stopped
        self.simulationState = initialSimulationState
        self.activeModules = initialActiveModules
        self.validationReport = SimulationConfigurationDerivation.validationReport(
            editorState: editorSettingsStore.editorState,
            transportState: .stopped,
            availableFiles: moduleCatalogStore.availableFiles
        )
        self.playbackTimelineSnapshot = .placeholder

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
                self.editorSettingsStore.normalizeAssignedModulePaths(availableFiles: availableFiles)
                self.recomputeAndApply(
                    editorState: self.editorSettingsStore.editorState,
                    availableFiles: availableFiles
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

        editorSettingsStore.normalizeAssignedModulePaths(availableFiles: moduleCatalogStore.availableFiles)
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
        session.updateTypeMatrixLocalSettings(physicsModuleSettingsStore.typeMatrixLocalSettings())
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

    func setPlaybackTime(_ seconds: Double) {
        guard activeModules.isPlaybackModuleFamily else { return }
        let boundedSeconds = min(max(0, seconds), playbackTimelineSnapshot.durationSeconds)
        playbackTimelineSnapshot.currentSeconds = boundedSeconds
        session.setPlaybackTime(boundedSeconds)
    }

    func setPlaybackLooping(_ isLooping: Bool) {
        guard activeModules.isPlaybackModuleFamily else { return }
        playbackTimelineSnapshot.isLooping = isLooping
        session.setPlaybackLooping(isLooping)
    }

    func beginPlaybackScrub() {
        guard activeModules.isPlaybackModuleFamily else { return }
        playbackScrubShouldResume = transportState == .running
        guard transportState == .running else { return }
        transportState = .paused
        InteractionSnapshotRecorder.shared.record(
            event: "ui.begin_playback_scrub",
            details: ["transport": "running_to_paused"]
        )
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
    }

    func endPlaybackScrub() {
        guard activeModules.isPlaybackModuleFamily else {
            playbackScrubShouldResume = false
            return
        }

        let shouldResume = playbackScrubShouldResume
        playbackScrubShouldResume = false
        guard shouldResume, transportState == .paused, validationReport.canStart else { return }
        transportState = .running
        InteractionSnapshotRecorder.shared.record(
            event: "ui.end_playback_scrub",
            details: ["transport": "paused_to_running"]
        )
        recomputeAndApply(
            editorState: editorSettingsStore.editorState,
            availableFiles: moduleCatalogStore.availableFiles
        )
    }

    func refreshPlaybackTimelineSnapshot() {
        guard activeModules.isPlaybackModuleFamily else {
            playbackTimelineSnapshot = .placeholder
            return
        }
        playbackTimelineSnapshot = session.playbackTimelineSnapshot
    }

    private func recomputeAndApply(
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) {
        let nextSimulationState = SimulationConfigurationDerivation.simulationState(
            transportState: transportState,
            editorState: editorState,
            availableFiles: availableFiles
        )
        let nextActiveModules = SimulationConfigurationDerivation.activeModules(
            editorState: editorState,
            availableFiles: availableFiles
        )
        let nextValidationReport = SimulationConfigurationDerivation.validationReport(
            editorState: editorState,
            transportState: transportState,
            availableFiles: availableFiles
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
        refreshPlaybackTimelineSnapshot()
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
