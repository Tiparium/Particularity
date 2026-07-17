import Foundation
import Metal

private final class PreparedSimulationBootstrap: @unchecked Sendable {
    let device: MTLDevice
    let library: MTLLibrary

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }
}

enum SimulationSessionError: LocalizedError {
    case missingDevice
    case shaderSourceLoadingFailed(String)
    case libraryCompilationFailed(String)
    case runtimeCreationFailed(SimulationRuntimeError)

    var errorDescription: String? {
        switch self {
        case .missingDevice:
            return "Simulation session could not acquire a Metal device."
        case .shaderSourceLoadingFailed(let message):
            return "Simulation session failed to load a Metal shader source file. \(message)"
        case .libraryCompilationFailed(let message):
            return "Simulation session failed to compile the shared Metal library. \(message)"
        case .runtimeCreationFailed(let error):
            return error.localizedDescription
        }
    }
}

@MainActor
final class SimulationSession {
    enum LifecycleState: String {
        case active
        case suspending
        case suspended
        case discarded
    }

    let device: MTLDevice
    let library: MTLLibrary
    private var runtime: SimulationRuntime?

    private let windowSuspendTimeout: TimeInterval = 0.5
    private let closedSimulationStaleTimeout: TimeInterval = 300.0

    private var metricsSink: @MainActor (SimulationPerformanceMetrics) -> Void
    private var leaderCommunicationLogSink: @MainActor ([LeaderCommunicationLogEntry]) -> Void
    private let viewportStateStore: MainWindowViewportStateStore
    private var currentSimulationState: SimulationViewportState
    private var activeModules: ActiveModuleSet
    private var typeMatrixLocalSettings = TypeMatrixLocalPhysicsSettings()
    private var lifecycleState: LifecycleState = .active
    private var suspensionStartedAt: TimeInterval?
    private var suspendTimeoutWorkItem: DispatchWorkItem?
    private var staleDiscardWorkItem: DispatchWorkItem?
    private var suspendGeneration: UInt64 = 0
    private var attachedViewportCount = 0

    private init(
        preparedBootstrap: PreparedSimulationBootstrap,
        metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void = { _ in },
        leaderCommunicationLogSink: @escaping @MainActor ([LeaderCommunicationLogEntry]) -> Void = { _ in },
        editorSettingsStore: MainWindowEditorSettingsStore = .shared,
        availableBundles: [ModuleBundle] = [],
        viewportStateStore: MainWindowViewportStateStore = .shared
    ) throws {
        self.metricsSink = metricsSink
        self.leaderCommunicationLogSink = leaderCommunicationLogSink
        self.viewportStateStore = viewportStateStore
        let resolvedConfiguration = SimulationConfigurationDerivation.resolvedRuntimeConfiguration(
            editorState: editorSettingsStore.editorState,
            transportState: .stopped,
            availableBundles: availableBundles
        )
        self.currentSimulationState = resolvedConfiguration.simulationState
        self.activeModules = resolvedConfiguration.activeModules

        self.device = preparedBootstrap.device
        self.library = preparedBootstrap.library
        self.runtime = try Self.makeRuntime(
            device: preparedBootstrap.device,
            library: preparedBootstrap.library,
            metricsSink: metricsSink,
            leaderCommunicationLogSink: leaderCommunicationLogSink
        )
        try applyStateToRuntime()
    }

    static func create(
        metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void = { _ in },
        leaderCommunicationLogSink: @escaping @MainActor ([LeaderCommunicationLogEntry]) -> Void = { _ in },
        editorSettingsStore: MainWindowEditorSettingsStore = .shared,
        availableBundles: [ModuleBundle] = [],
        viewportStateStore: MainWindowViewportStateStore = .shared
    ) async throws -> SimulationSession {
        let preparedBootstrap = try await Self.prepareBootstrap()
        return try SimulationSession(
            preparedBootstrap: preparedBootstrap,
            metricsSink: metricsSink,
            leaderCommunicationLogSink: leaderCommunicationLogSink,
            editorSettingsStore: editorSettingsStore,
            availableBundles: availableBundles,
            viewportStateStore: viewportStateStore
        )
    }

    var simulationState: SimulationViewportState {
        currentSimulationState
    }

    var viewportState: ViewportState {
        viewportStateStore.viewportState
    }

    var sceneState: SceneState {
        viewportStateStore.sceneState
    }

    var renderState: SimulationRuntime.RenderState {
        runtime?.renderState ?? SimulationRuntime.RenderState(
            particleBuffer: nil,
            activeParticleCount: 0,
            particleCapacity: 0,
            debugLineBuffer: nil,
            debugRenderSegments: []
        )
    }

    var playbackTimelineState: PlaybackTimelineState {
        runtime?.playbackTimelineState ?? PlaybackTimelineState()
    }

    func updateSimulationState(_ nextState: SimulationViewportState) {
        let previousTransportState = currentSimulationState.transportState
        currentSimulationState = nextState
        InteractionSnapshotRecorder.shared.record(
            event: "session.update_simulation_state",
            details: ["state": InteractionSnapshotFormat.viewport(nextState)]
        )
        if nextState.transportState == .paused, previousTransportState != .paused {
            viewportStateStore.flushPersistence()
        }
        runtime?.updateSimulationState(nextState)
    }

    func updateViewportState(_ nextState: ViewportState) {
        viewportStateStore.updateViewportState(nextState)
    }

    func updateSceneState(_ nextState: SceneState) {
        viewportStateStore.updateSceneState(nextState)
    }

    func updateActiveModules(_ nextModules: ActiveModuleSet) throws {
        if let reason = ModuleCompatibility.incompatibilityReason(for: nextModules, state: currentSimulationState) {
            throw SimulationRuntimeError.incompatibleModules(nextModules, reason)
        }
        activeModules = nextModules
        InteractionSnapshotRecorder.shared.record(
            event: "session.update_active_modules",
            details: ["activeModules": InteractionSnapshotFormat.activeModules(nextModules)]
        )
        try runtime?.updateActiveModules(nextModules)
    }

    func updateTypeMatrixLocalSettings(_ nextSettings: TypeMatrixLocalPhysicsSettings) {
        typeMatrixLocalSettings = nextSettings
        InteractionSnapshotRecorder.shared.record(
            event: "session.update_type_matrix_settings",
            details: [
                "nonce": "\(nextSettings.regenerationNonce)",
                "minimum": "\(nextSettings.matrixMinimumValue)",
                "maximum": "\(nextSettings.matrixMaximumValue)",
            ]
        )
        runtime?.updateTypeMatrixLocalSettings(nextSettings)
    }

    func seekPlayback(to seconds: Double) {
        runtime?.seekPlayback(to: seconds)
    }

    func publishFrameMetrics(averageFPS: Double, at now: TimeInterval) {
        runtime?.publishFrameMetrics(averageFPS: averageFPS, at: now)
    }

    func attachViewport() {
        attachedViewportCount += 1
        suspendGeneration &+= 1
        suspendTimeoutWorkItem?.cancel()
        suspendTimeoutWorkItem = nil
        staleDiscardWorkItem?.cancel()
        staleDiscardWorkItem = nil
        suspensionStartedAt = nil
        lifecycleState = .active
        do {
            try ensureRuntime()
        } catch {
            RuntimeEventLogger.log("window resume failed error=\(error.localizedDescription)")
            return
        }
        runtime?.resumeTicking()
        InteractionSnapshotRecorder.shared.record(
            event: "session.attach_viewport",
            details: ["attachedViewportCount": "\(attachedViewportCount)"]
        )
        RuntimeEventLogger.log("window resume requested attached_viewports=\(attachedViewportCount)")
    }

    func detachViewport() {
        attachedViewportCount = max(0, attachedViewportCount - 1)
        guard attachedViewportCount == 0 else {
            RuntimeEventLogger.log("window detach ignored attached_viewports=\(attachedViewportCount)")
            return
        }
        suspendGeneration &+= 1
        let activeParticleCount = runtime?.renderState.activeParticleCount ?? 0
        let completedAt = ProcessInfo.processInfo.systemUptime
        let startedAt = suspensionStartedAt ?? completedAt
        let elapsedMs = (completedAt - startedAt) * 1000.0
        suspensionStartedAt = nil
        suspendTimeoutWorkItem?.cancel()
        suspendTimeoutWorkItem = nil
        staleDiscardWorkItem?.cancel()
        staleDiscardWorkItem = nil
        viewportStateStore.flushPersistence()

        currentSimulationState.transportState = .stopped
        runtime?.updateSimulationState(currentSimulationState)
        runtime?.discardEphemeralState()
        runtime = nil
        lifecycleState = .discarded
        InteractionSnapshotRecorder.shared.record(
            event: "session.detach_viewport",
            details: [
                "activeParticlesBeforeDetach": "\(activeParticleCount)",
                "attachedViewportCount": "\(attachedViewportCount)",
            ]
        )

        RuntimeEventLogger.log(
            "window close forced_stop duration_ms=\(String(format: "%.2f", elapsedMs)) active_particles=\(activeParticleCount)"
        )
    }

    private static func makeRuntime(
        device: MTLDevice,
        library: MTLLibrary,
        metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void,
        leaderCommunicationLogSink: @escaping @MainActor ([LeaderCommunicationLogEntry]) -> Void
    ) throws -> SimulationRuntime {
        do {
            return try SimulationRuntime(
                device: device,
                library: library,
                metricsSink: metricsSink,
                leaderCommunicationLogSink: leaderCommunicationLogSink
            )
        } catch let error as SimulationRuntimeError {
            throw SimulationSessionError.runtimeCreationFailed(error)
        } catch {
            throw SimulationSessionError.libraryCompilationFailed(error.localizedDescription)
        }
    }

    nonisolated private static func prepareBootstrap() async throws -> PreparedSimulationBootstrap {
        try await Task.detached(priority: .userInitiated) {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw SimulationSessionError.missingDevice
            }

            let defaultPhysicsSource = try PhysicsShaderSourceFiles.defaultPhysicsSource()
            let packagedPhysicsSources = try PhysicsShaderSourceFiles.packagedPhysicsSources()
            let librarySource = [
                SimulationMetalSharedSource.source,
                DefaultVisualModuleRuntime.shaderSource,
                MLTrainingPlaybackPresenterRuntime.shaderSource,
                defaultPhysicsSource,
                packagedPhysicsSources.joined(separator: "\n\n"),
                DefaultOptimizationModuleRuntime.computeShaderSource,
                FixedGridOptimizationModuleRuntime.computeShaderSource,
            ].joined(separator: "\n\n")

            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: librarySource, options: nil)
            } catch {
                throw SimulationSessionError.libraryCompilationFailed(error.localizedDescription)
            }

            return PreparedSimulationBootstrap(device: device, library: library)
        }.value
    }

    private func ensureRuntime() throws {
        guard runtime == nil else {
            try applyStateToRuntime()
            return
        }
        let nextRuntime = try Self.makeRuntime(
            device: device,
            library: library,
            metricsSink: metricsSink,
            leaderCommunicationLogSink: leaderCommunicationLogSink
        )
        runtime = nextRuntime
        try applyStateToRuntime()
    }

    private func applyStateToRuntime() throws {
        guard let runtime else { return }
        try runtime.updateActiveModules(activeModules)
        runtime.updateTypeMatrixLocalSettings(typeMatrixLocalSettings)
        runtime.updateSimulationState(currentSimulationState)
    }
}

@MainActor
final class WindowSimulationSessionStore {
    static let shared = WindowSimulationSessionStore()

    private var mainSession: SimulationSession?
    private let mainChromeStateStore = MainWindowChromeStateStore.shared
    private let mainEditorSettingsStore = MainWindowEditorSettingsStore.shared
    private let mainViewportStateStore = MainWindowViewportStateStore.shared
    private let mainPhysicsModuleSettingsStore = MainWindowPhysicsModuleSettingsStore.shared
    private let mainModuleCatalogStore = MainWindowModuleCatalogStore.shared
    private let mainDiagnosticsStore = MainWindowDiagnosticsStore.shared
    private let mainDebugSettingsStore = MainWindowDebugSettingsStore.shared
    private var mainRuntimeConfigCoordinator: SimulationRuntimeConfigCoordinator?

    func mainWindowChromeStateStore() -> MainWindowChromeStateStore {
        mainChromeStateStore
    }

    func mainWindowEditorSettingsStore() -> MainWindowEditorSettingsStore {
        mainEditorSettingsStore
    }

    func mainWindowViewportStateStore() -> MainWindowViewportStateStore {
        mainViewportStateStore
    }

    func mainWindowPhysicsModuleSettingsStore() -> MainWindowPhysicsModuleSettingsStore {
        mainPhysicsModuleSettingsStore
    }

    func mainWindowModuleCatalogStore() -> MainWindowModuleCatalogStore {
        mainModuleCatalogStore
    }

    func mainWindowDiagnosticsStore() -> MainWindowDiagnosticsStore {
        mainDiagnosticsStore
    }

    func mainWindowDebugSettingsStore() -> MainWindowDebugSettingsStore {
        mainDebugSettingsStore
    }

    func mainWindowRuntimeConfigCoordinator() async throws -> SimulationRuntimeConfigCoordinator {
        if let mainRuntimeConfigCoordinator {
            return mainRuntimeConfigCoordinator
        }

        let coordinator = SimulationRuntimeConfigCoordinator(
            session: try await mainWindowSession(),
            editorSettingsStore: mainEditorSettingsStore,
            physicsModuleSettingsStore: mainPhysicsModuleSettingsStore,
            moduleCatalogStore: mainModuleCatalogStore
        )
        mainRuntimeConfigCoordinator = coordinator
        return coordinator
    }

    func mainWindowSession() async throws -> SimulationSession {
        if let mainSession {
            return mainSession
        }

        let session = try await SimulationSession.create(
            metricsSink: { [weak diagnosticsStore = mainDiagnosticsStore] metrics in
                diagnosticsStore?.updatePerformanceMetrics(metrics)
            },
            leaderCommunicationLogSink: { [weak diagnosticsStore = mainDiagnosticsStore] entries in
                diagnosticsStore?.updateLeaderCommunicationLogEntries(entries)
            },
            editorSettingsStore: mainEditorSettingsStore,
            availableBundles: mainModuleCatalogStore.availableBundles,
            viewportStateStore: mainViewportStateStore
        )
        session.updateTypeMatrixLocalSettings(mainPhysicsModuleSettingsStore.typeMatrixLocalSettings())
        mainSession = session
        return session
    }
}
