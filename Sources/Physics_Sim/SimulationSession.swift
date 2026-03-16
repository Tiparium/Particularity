import Foundation
import Metal

enum SimulationSessionError: LocalizedError {
    case missingDevice
    case libraryCompilationFailed(String)
    case runtimeCreationFailed(SimulationRuntimeError)

    var errorDescription: String? {
        switch self {
        case .missingDevice:
            return "Simulation session could not acquire a Metal device."
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
    private let editorSettingsStore: MainWindowEditorSettingsStore
    private let viewportStateStore: MainWindowViewportStateStore
    private var currentSimulationState: SimulationViewportState
    private var activeModules: ActiveModuleSet
    private var metricsEnabled = true
    private var lifecycleState: LifecycleState = .active
    private var suspensionStartedAt: TimeInterval?
    private var suspendTimeoutWorkItem: DispatchWorkItem?
    private var staleDiscardWorkItem: DispatchWorkItem?
    private var suspendGeneration: UInt64 = 0
    private var attachedViewportCount = 0

    init(
        metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void = { _ in },
        editorSettingsStore: MainWindowEditorSettingsStore = .shared,
        viewportStateStore: MainWindowViewportStateStore = .shared
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SimulationSessionError.missingDevice
        }

        let librarySource = [
            DefaultVisualModuleRuntime.shaderSource,
            DefaultPhysicsModuleRuntime.computeShaderSource,
            DefaultOptimizationModuleRuntime.computeShaderSource,
        ].joined(separator: "\n\n")

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: librarySource, options: nil)
        } catch {
            throw SimulationSessionError.libraryCompilationFailed(error.localizedDescription)
        }

        self.metricsSink = metricsSink
        self.editorSettingsStore = editorSettingsStore
        self.viewportStateStore = viewportStateStore
        self.currentSimulationState = Self.makeSimulationViewportState(from: editorSettingsStore.editorState)
        self.activeModules = ActiveModuleSet(
            physics: ModuleCatalog.defaultPhysics,
            visual: ModuleCatalog.defaultVisual,
            optimization: ModuleCatalog.defaultOptimization
        )

        self.device = device
        self.library = library
        self.runtime = try Self.makeRuntime(device: device, library: library, metricsSink: metricsSink)
        try applyStateToRuntime()
    }

    private static func makeSimulationViewportState(from editorState: SimulationEditorState) -> SimulationViewportState {
        SimulationViewportState(
            transportState: .stopped,
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
            showOptimizationInfo: editorState.visualState.showOptimizationInfo,
            optimizationBlockingMode: editorState.optimizationState.blockingMode
        )
    }

    func setMetricsSink(_ sink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void) {
        metricsSink = sink
        runtime?.setMetricsSink(sink)
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
            particlePositionBuffer: nil,
            particleColorBuffer: nil,
            activeParticleCount: 0,
            particleCapacity: 0,
            debugLineBuffer: nil,
            debugRenderSegments: []
        )
    }

    func updateSimulationState(_ nextState: SimulationViewportState) {
        currentSimulationState = nextState
        InteractionSnapshotRecorder.shared.record(
            event: "session.update_simulation_state",
            details: ["state": InteractionSnapshotFormat.viewport(nextState)]
        )
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

    func setMetricsEnabled(_ enabled: Bool) {
        metricsEnabled = enabled
        runtime?.setMetricsEnabled(enabled)
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
        metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void
    ) throws -> SimulationRuntime {
        do {
            return try SimulationRuntime(device: device, library: library, metricsSink: metricsSink)
        } catch let error as SimulationRuntimeError {
            throw SimulationSessionError.runtimeCreationFailed(error)
        } catch {
            throw SimulationSessionError.libraryCompilationFailed(error.localizedDescription)
        }
    }

    private func ensureRuntime() throws {
        guard runtime == nil else {
            try applyStateToRuntime()
            return
        }
        let nextRuntime = try Self.makeRuntime(device: device, library: library, metricsSink: metricsSink)
        runtime = nextRuntime
        try applyStateToRuntime()
    }

    private func applyStateToRuntime() throws {
        guard let runtime else { return }
        try runtime.updateActiveModules(activeModules)
        runtime.setMetricsEnabled(metricsEnabled)
        runtime.updateSimulationState(currentSimulationState)
    }
}

@MainActor
final class WindowSimulationSessionStore {
    static let shared = WindowSimulationSessionStore()

    private var mainSession: SimulationSession?
    private let mainEditorSettingsStore = MainWindowEditorSettingsStore.shared
    private let mainViewportStateStore = MainWindowViewportStateStore.shared
    private let mainModuleCatalogStore = MainWindowModuleCatalogStore.shared
    private var mainRuntimeConfigCoordinator: SimulationRuntimeConfigCoordinator?

    func mainWindowEditorSettingsStore() -> MainWindowEditorSettingsStore {
        mainEditorSettingsStore
    }

    func mainWindowViewportStateStore() -> MainWindowViewportStateStore {
        mainViewportStateStore
    }

    func mainWindowModuleCatalogStore() -> MainWindowModuleCatalogStore {
        mainModuleCatalogStore
    }

    func mainWindowRuntimeConfigCoordinator() throws -> SimulationRuntimeConfigCoordinator {
        if let mainRuntimeConfigCoordinator {
            return mainRuntimeConfigCoordinator
        }

        let coordinator = SimulationRuntimeConfigCoordinator(
            session: try mainWindowSession(metricsSink: { _ in }),
            editorSettingsStore: mainEditorSettingsStore,
            moduleCatalogStore: mainModuleCatalogStore
        )
        mainRuntimeConfigCoordinator = coordinator
        return coordinator
    }

    func mainWindowSession(metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void) throws -> SimulationSession {
        if let mainSession {
            mainSession.setMetricsSink(metricsSink)
            return mainSession
        }

        let session = try SimulationSession(
            metricsSink: metricsSink,
            editorSettingsStore: mainEditorSettingsStore,
            viewportStateStore: mainViewportStateStore
        )
        mainSession = session
        return session
    }
}
