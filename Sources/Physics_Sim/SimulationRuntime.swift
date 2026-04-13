import Foundation
import Metal
import QuartzCore
import simd

enum SimulationRuntimeError: LocalizedError {
    case missingFunction(String)
    case missingCommandQueue
    case computePipelineCreationFailed(String)
    case incompatibleModules(ActiveModuleSet, String)

    var errorDescription: String? {
        switch self {
        case .missingFunction(let name):
            return "Simulation runtime is missing the Metal function '\(name)'."
        case .missingCommandQueue:
            return "Simulation runtime could not create a Metal command queue."
        case .computePipelineCreationFailed(let name):
            return "Simulation runtime failed to create the compute pipeline for '\(name)'."
        case .incompatibleModules(let modules, let reason):
            return "Incompatible active modules: physics=\(modules.physics.name), visual=\(modules.visual.name), optimization=\(modules.optimization.name). \(reason)"
        }
    }
}

private struct SimulationPhysicsAccumulateParams {
    var particleCount: UInt32
    var interactionRadius: Float
    var impulseScale: Float
    var neighborReadMode: UInt32 = 0
}

private struct SimulationPhysicsApplyParams {
    var movementDirection: SIMD4<Float>
    var particleCount: UInt32
    var deltaTime: Float
    var velocityDamping: Float
}

private struct TypeMatrixPhysicsAccumulateParams {
    var particleCount: UInt32
    var particleTypeCount: UInt32
    var neighborReadMode: UInt32
    var padding0: UInt32 = 0
    var innerRadius: Float
    var middleRadius: Float
    var outerRadius: Float
    var attractionMultiplier: Float
    var repulsionMultiplier: Float
    var matrixSideLength: UInt32
    var teleportationEnabled: UInt32
    var teleportationGeneralBudget: UInt32
    var teleportationSelfBudget: UInt32
    var teleportationSelfBudgetLinked: UInt32
    var teleportationAccumulation: Float
    var teleportationRecoveryRate: Float
}

private struct TypeMatrixPhysicsApplyParams {
    var particleCount: UInt32
    var deltaTime: Float
    var dampingEnabled: UInt32
    var momentumEnabled: UInt32
    var speedLimitEnabled: UInt32
    var dampingStrength: Float
    var momentumStrength: Float
    var speedLimit: Float
    var teleportationEnabled: UInt32
    var teleportationMinimumDistance: Float
}

private struct TemplatePhysicsAccumulateParams {
    var particleCount: UInt32
    var interactionRadius: Float
    var impulseScale: Float
    var neighborReadMode: UInt32 = 0
}

private struct TemplatePhysicsApplyParams {
    var particleCount: UInt32
    var deltaTime: Float
    var velocityDamping: Float
    var padding0: Float = 0
}

private struct SimulationDebugLineParams {
    var segmentCount: UInt32
    var particleCount: UInt32
    var neighborReadMode: UInt32 = 0
    var padding1: UInt32 = 0
}

private struct FixedGridAssignParticlesParams {
    var particleCount: UInt32
    var subdivisions: UInt32
    var neighborReadMode: UInt32 = 0
    var padding1: UInt32 = 0
}

private struct FixedGridCellCountParams {
    var cellCount: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
}

private struct FixedGridScanStepParams {
    var cellCount: UInt32
    var stride: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
}

struct SimulationDebugLineSegment {
    var sourceParticleIndex: UInt32
    var interactionCount: UInt32
    var firstVertexIndex: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
    var padding3: UInt32 = 0
}

private struct SimulationLineVertex {
    var position: SIMD3<Float>
}

struct SimulationDebugRenderSegment {
    var vertexStart: Int
    var vertexCount: Int
    var startedAt: TimeInterval
}

final class SimulationRuntime: @unchecked Sendable {
    struct RenderState {
        let particleBuffer: MTLBuffer?
        let activeParticleCount: Int
        let particleCapacity: Int
        let debugLineBuffer: MTLBuffer?
        let debugRenderSegments: [SimulationDebugRenderSegment]
        let playbackActivationMinimum: Float
        let playbackActivationMaximum: Float

        var particlePositionBuffer: MTLBuffer? { particleBuffer }
        var particleColorBuffer: MTLBuffer? { nil }
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let defaultPhysicsAccumulatePipeline: MTLComputePipelineState
    private let defaultPhysicsApplyPipeline: MTLComputePipelineState
    private let templatePhysicsAccumulatePipeline: MTLComputePipelineState
    private let templatePhysicsApplyPipeline: MTLComputePipelineState
    private let typeMatrixPhysicsAccumulatePipeline: MTLComputePipelineState
    private let typeMatrixPhysicsApplyPipeline: MTLComputePipelineState
    private let debugLinePipeline: MTLComputePipelineState
    private let fixedGridClearCellCountsPipeline: MTLComputePipelineState
    private let fixedGridAssignParticlesPipeline: MTLComputePipelineState
    private let fixedGridPrepareGroupRangesPipeline: MTLComputePipelineState
    private let fixedGridScanGroupRangesPipeline: MTLComputePipelineState
    private let fixedGridFinalizeGroupRangesPipeline: MTLComputePipelineState
    private let fixedGridScatterParticleIndicesPipeline: MTLComputePipelineState
    private var metricsSink: @MainActor (SimulationPerformanceMetrics) -> Void
    private var leaderCommunicationLogSink: @MainActor ([LeaderCommunicationLogEntry]) -> Void
    private let simulationQueue = DispatchQueue(label: "physics-sim.runtime.queue", qos: .userInitiated)
    private let snapshotLock = NSLock()
    private let playbackSeekLock = NSLock()

    private var simulationTimer: DispatchSourceTimer?
    private var simulationWorkInFlight = false
    private var tickingSuspended = false
    private var idleCallbacks: [@Sendable () -> Void] = []
    private var pendingPlaybackSeekSeconds: Double?
    private var playbackSeekScheduled = false

    private var particleFrontBuffer: MTLBuffer?
    private var particleBackBuffer: MTLBuffer?
    private var interactionGroupIndicesBuffer: MTLBuffer?
    private var interactionRangeOffsetsBuffer: MTLBuffer?
    private var interactionRangeTargetsBuffer: MTLBuffer?
    private var interactionRangesBuffer: MTLBuffer?
    private var interactionIndicesBuffer: MTLBuffer?
    private var interactionScratchParticlesBuffer: MTLBuffer?
    private var interactionScratchToCanonicalBuffer: MTLBuffer?
    private var fixedGridCellCountsBuffer: MTLBuffer?
    private var fixedGridCellOffsetsBuffer: MTLBuffer?
    private var fixedGridCellWriteHeadsBuffer: MTLBuffer?
    private var fixedGridCellScanBufferA: MTLBuffer?
    private var fixedGridCellScanBufferB: MTLBuffer?
    private var typeMatrixInteractionBuffer: MTLBuffer?
    private var typeMatrixSidecarFrontBuffer: MTLBuffer?
    private var typeMatrixSidecarBackBuffer: MTLBuffer?
    private var debugLineBuffer: MTLBuffer?
    private var debugLineSegmentBuffer: MTLBuffer?
    private var activeParticleCount = 0
    private var particleCapacity = 0
    private var playbackActivationMinimum: Float = 0
    private var playbackActivationMaximum: Float = 1
    private var debugHistory = SimulationDebugHistory(historyCapacity: 8, visibilityDuration: 0.11)
    private var leaderCommunicationLogEntries: [LeaderCommunicationLogEntry] = []
    private var needsParticleRebuild = true
    private var needsInteractionPlanRefresh = true
    private var cachedDefaultInteractionParticleCount: Int?
    private var cachedFixedGridTopology: FixedGridInteractionTopology?
    private var typeMatrixLocalSettings = TypeMatrixLocalPhysicsSettings()
    private var currentSimulationState = SimulationViewportState(
        transportState: .stopped,
        particleCount: 20_000,
        randomDistribution: true,
        particleTypes: 6,
        allParticlesIntercommunicate: true,
        movementDirection: SIMD3<Float>(0.82, 0.18, 0.12),
        timeScale: 1.0,
        sphereSize: 0.025,
        spectrumOffset: 0.0,
        showOptimizationInfo: false,
        mlPlaybackRecipe: .typeSpectrum,
        mlPlaybackNormalizationMode: .global,
        isPlaybackVisualModule: false,
        playbackTimeScale: 1.0,
        playbackInterpolationEnabled: false,
        playbackSurfaceMeshEnabled: false,
        playbackSurfaceSmoothing: 0,
        playbackFrontLayerVisible: true,
        playbackMiddleLayerVisible: true,
        playbackFinalLayerVisible: true,
        playbackFrontLayerSlot: 0,
        playbackMiddleLayerSlot: 0,
        playbackFinalLayerSlot: 0,
        playbackFrontLayerOffset: 0.32,
        playbackMiddleLayerOffset: 0,
        playbackFinalLayerOffset: -0.32,
        showLeaderCommunicationLog: false,
        fixedGridSubdivisions: FixedGridOptimizationModuleRuntime.defaultSubdivisions,
        fixedGridSubspaceCap: 2,
        fixedGridNeighborReadMode: .scratch
    )
    private var activeModules = ActiveModuleSet(
        physics: ModuleCatalog.defaultPhysics,
        visual: ModuleCatalog.defaultVisual,
        optimization: ModuleCatalog.defaultOptimization
    )
    private var playbackFixture: MLPlaybackPrototypeFixture?
    private var playbackCurrentSeconds: Double = 0
    private var playbackLastUptime: TimeInterval?
    private var playbackLooping = true

    private var renderStateSnapshot = RenderState(
        particleBuffer: nil,
        activeParticleCount: 0,
        particleCapacity: 0,
        debugLineBuffer: nil,
        debugRenderSegments: [],
        playbackActivationMinimum: 0,
        playbackActivationMaximum: 1
    )
    private var simulationStateSnapshot = SimulationViewportState(
        transportState: .stopped,
        particleCount: 20_000,
        randomDistribution: true,
        particleTypes: 6,
        allParticlesIntercommunicate: true,
        movementDirection: SIMD3<Float>(0.82, 0.18, 0.12),
        timeScale: 1.0,
        sphereSize: 0.025,
        spectrumOffset: 0.0,
        showOptimizationInfo: false,
        mlPlaybackRecipe: .typeSpectrum,
        mlPlaybackNormalizationMode: .global,
        isPlaybackVisualModule: false,
        playbackTimeScale: 1.0,
        playbackInterpolationEnabled: false,
        playbackSurfaceMeshEnabled: false,
        playbackSurfaceSmoothing: 0,
        playbackFrontLayerVisible: true,
        playbackMiddleLayerVisible: true,
        playbackFinalLayerVisible: true,
        playbackFrontLayerSlot: 0,
        playbackMiddleLayerSlot: 0,
        playbackFinalLayerSlot: 0,
        playbackFrontLayerOffset: 0.32,
        playbackMiddleLayerOffset: 0,
        playbackFinalLayerOffset: -0.32,
        showLeaderCommunicationLog: false,
        fixedGridSubdivisions: FixedGridOptimizationModuleRuntime.defaultSubdivisions,
        fixedGridSubspaceCap: 2,
        fixedGridNeighborReadMode: .scratch
    )

    private var metricsAccumulator = SimulationMetricsAccumulator(sampleWindowSeconds: 3.0, publishInterval: 0.25)
    private let fixedTimeStep: Float = 1.0 / 60.0
    private let simulationTickInterval: TimeInterval = 1.0 / 60.0
    private let physicsThreadsPerGroup = 256
    private let debugHistorySegmentCapacity = 8
    private let simulationQueueKey = DispatchSpecificKey<Void>()

    init(
        device: MTLDevice,
        library: MTLLibrary,
        metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void = { _ in },
        leaderCommunicationLogSink: @escaping @MainActor ([LeaderCommunicationLogEntry]) -> Void = { _ in }
    ) throws {
        guard let physicsAccumulateFunction = library.makeFunction(name: "physics_accumulate_impulse") else {
            throw SimulationRuntimeError.missingFunction("physics_accumulate_impulse")
        }
        guard let physicsApplyFunction = library.makeFunction(name: "physics_apply_impulse") else {
            throw SimulationRuntimeError.missingFunction("physics_apply_impulse")
        }
        guard let templatePhysicsAccumulateFunction = library.makeFunction(name: "template_physics_accumulate_impulse") else {
            throw SimulationRuntimeError.missingFunction("template_physics_accumulate_impulse")
        }
        guard let templatePhysicsApplyFunction = library.makeFunction(name: "template_physics_apply_impulse") else {
            throw SimulationRuntimeError.missingFunction("template_physics_apply_impulse")
        }
        guard let typeMatrixAccumulateFunction = library.makeFunction(name: "type_matrix_accumulate_impulse") else {
            throw SimulationRuntimeError.missingFunction("type_matrix_accumulate_impulse")
        }
        guard let typeMatrixApplyFunction = library.makeFunction(name: "type_matrix_apply_impulse") else {
            throw SimulationRuntimeError.missingFunction("type_matrix_apply_impulse")
        }
        guard let debugLineFunction = library.makeFunction(name: "build_debug_lines") else {
            throw SimulationRuntimeError.missingFunction("build_debug_lines")
        }
        guard let fixedGridClearCellCountsFunction = library.makeFunction(name: "fixed_grid_clear_cell_counts") else {
            throw SimulationRuntimeError.missingFunction("fixed_grid_clear_cell_counts")
        }
        guard let fixedGridAssignParticlesFunction = library.makeFunction(name: "fixed_grid_assign_particles_to_groups") else {
            throw SimulationRuntimeError.missingFunction("fixed_grid_assign_particles_to_groups")
        }
        guard let fixedGridPrepareGroupRangesFunction = library.makeFunction(name: "fixed_grid_build_group_ranges") else {
            throw SimulationRuntimeError.missingFunction("fixed_grid_build_group_ranges")
        }
        guard let fixedGridScanGroupRangesFunction = library.makeFunction(name: "fixed_grid_scan_group_ranges") else {
            throw SimulationRuntimeError.missingFunction("fixed_grid_scan_group_ranges")
        }
        guard let fixedGridFinalizeGroupRangesFunction = library.makeFunction(name: "fixed_grid_finalize_group_ranges") else {
            throw SimulationRuntimeError.missingFunction("fixed_grid_finalize_group_ranges")
        }
        guard let fixedGridScatterParticleIndicesFunction = library.makeFunction(name: "fixed_grid_scatter_particle_indices") else {
            throw SimulationRuntimeError.missingFunction("fixed_grid_scatter_particle_indices")
        }

        do {
            self.defaultPhysicsAccumulatePipeline = try device.makeComputePipelineState(function: physicsAccumulateFunction)
            self.defaultPhysicsApplyPipeline = try device.makeComputePipelineState(function: physicsApplyFunction)
            self.templatePhysicsAccumulatePipeline = try device.makeComputePipelineState(function: templatePhysicsAccumulateFunction)
            self.templatePhysicsApplyPipeline = try device.makeComputePipelineState(function: templatePhysicsApplyFunction)
            self.typeMatrixPhysicsAccumulatePipeline = try device.makeComputePipelineState(function: typeMatrixAccumulateFunction)
            self.typeMatrixPhysicsApplyPipeline = try device.makeComputePipelineState(function: typeMatrixApplyFunction)
            self.debugLinePipeline = try device.makeComputePipelineState(function: debugLineFunction)
            self.fixedGridClearCellCountsPipeline = try device.makeComputePipelineState(function: fixedGridClearCellCountsFunction)
            self.fixedGridAssignParticlesPipeline = try device.makeComputePipelineState(function: fixedGridAssignParticlesFunction)
            self.fixedGridPrepareGroupRangesPipeline = try device.makeComputePipelineState(function: fixedGridPrepareGroupRangesFunction)
            self.fixedGridScanGroupRangesPipeline = try device.makeComputePipelineState(function: fixedGridScanGroupRangesFunction)
            self.fixedGridFinalizeGroupRangesPipeline = try device.makeComputePipelineState(function: fixedGridFinalizeGroupRangesFunction)
            self.fixedGridScatterParticleIndicesPipeline = try device.makeComputePipelineState(function: fixedGridScatterParticleIndicesFunction)
        } catch {
            let description = (error as NSError).localizedDescription
            let failingName: String
            if description.contains("physics_accumulate_impulse") {
                failingName = "physics_accumulate_impulse"
            } else if description.contains("physics_apply_impulse") {
                failingName = "physics_apply_impulse"
            } else if description.contains("template_physics_accumulate_impulse") {
                failingName = "template_physics_accumulate_impulse"
            } else if description.contains("template_physics_apply_impulse") {
                failingName = "template_physics_apply_impulse"
            } else if description.contains("type_matrix_accumulate_impulse") {
                failingName = "type_matrix_accumulate_impulse"
            } else if description.contains("type_matrix_apply_impulse") {
                failingName = "type_matrix_apply_impulse"
            } else if description.contains("fixed_grid_clear_cell_counts") {
                failingName = "fixed_grid_clear_cell_counts"
            } else if description.contains("fixed_grid_assign_particles_to_groups") {
                failingName = "fixed_grid_assign_particles_to_groups"
            } else if description.contains("fixed_grid_build_group_ranges") {
                failingName = "fixed_grid_build_group_ranges"
            } else if description.contains("fixed_grid_scan_group_ranges") {
                failingName = "fixed_grid_scan_group_ranges"
            } else if description.contains("fixed_grid_finalize_group_ranges") {
                failingName = "fixed_grid_finalize_group_ranges"
            } else if description.contains("fixed_grid_scatter_particle_indices") {
                failingName = "fixed_grid_scatter_particle_indices"
            } else {
                failingName = "build_debug_lines"
            }
            throw SimulationRuntimeError.computePipelineCreationFailed(failingName)
        }

        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw SimulationRuntimeError.missingCommandQueue
        }
        self.commandQueue = commandQueue
        self.metricsSink = metricsSink
        self.leaderCommunicationLogSink = leaderCommunicationLogSink
        self.simulationQueue.setSpecific(key: simulationQueueKey, value: ())
        publishSnapshots()
    }

    deinit {
        simulationTimer?.cancel()
        simulationTimer = nil
    }

    var renderState: RenderState {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return renderStateSnapshot
    }

    var simulationState: SimulationViewportState {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return simulationStateSnapshot
    }

    var playbackTimelineSnapshot: PlaybackTimelineSnapshot {
        simulationQueue.sync {
            makePlaybackTimelineSnapshot()
        }
    }

    func updateTypeMatrixLocalSettings(_ nextSettings: TypeMatrixLocalPhysicsSettings) {
        simulationQueue.async {
            self.typeMatrixLocalSettings = nextSettings
            RuntimeEventLogger.log(
                "type_matrix runtime_update nonce=\(nextSettings.regenerationNonce) transport=\(self.currentSimulationState.transportState.rawValue) active=\(self.isTypeMatrixPhysicsActive)"
            )
            guard self.currentSimulationState.transportState != .stopped,
                  self.isTypeMatrixPhysicsActive else {
                return
            }
            self.uploadTypeMatrixInteractionBuffer(from: nextSettings.matrixValues)
        }
    }

    func setPlaybackTime(_ seconds: Double) {
        playbackSeekLock.lock()
        pendingPlaybackSeekSeconds = seconds
        let shouldSchedule = !playbackSeekScheduled
        if shouldSchedule {
            playbackSeekScheduled = true
        }
        playbackSeekLock.unlock()

        guard shouldSchedule else { return }
        simulationQueue.async {
            self.processLatestPlaybackSeek()
        }
    }

    func setPlaybackLooping(_ isLooping: Bool) {
        simulationQueue.async {
            self.playbackLooping = isLooping
        }
    }

    private func makePlaybackTimelineSnapshot() -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            currentSeconds: playbackCurrentSeconds,
            durationSeconds: playbackFixture?.durationSeconds ?? PlaybackTimelineSnapshot.placeholder.durationSeconds,
            isLooping: playbackLooping,
            playbackTimeScale: Double(currentSimulationState.playbackTimeScale),
            interpolationEnabled: currentSimulationState.playbackInterpolationEnabled
        )
    }

    private func processLatestPlaybackSeek() {
        playbackSeekLock.lock()
        guard let seconds = pendingPlaybackSeekSeconds else {
            playbackSeekScheduled = false
            playbackSeekLock.unlock()
            return
        }
        pendingPlaybackSeekSeconds = nil
        playbackSeekLock.unlock()

        applyPlaybackSeek(seconds)

        playbackSeekLock.lock()
        let hasPendingSeek = pendingPlaybackSeekSeconds != nil
        if !hasPendingSeek {
            playbackSeekScheduled = false
        }
        playbackSeekLock.unlock()

        if hasPendingSeek {
            simulationQueue.async {
                self.processLatestPlaybackSeek()
            }
        }
    }

    private func applyPlaybackSeek(_ seconds: Double) {
        guard activeModules.isPlaybackModuleFamily else { return }
        guard let fixture = playbackFixture ?? MLPlaybackPrototypeFixtureLoader.loadFixture() else { return }
        playbackFixture = fixture
        playbackCurrentSeconds = min(max(0, seconds), fixture.durationSeconds)
        playbackLastUptime = ProcessInfo.processInfo.systemUptime
        let selection = currentPlaybackSurfaceSelection()
        let frame = currentSimulationState.playbackInterpolationEnabled
            ? fixture.interpolatedParticles(
                at: playbackCurrentSeconds,
                selection: selection
            )
            : fixture.particles(
                at: playbackCurrentSeconds,
                selection: selection
            )
        uploadPlaybackParticles(frame.particles)
        publishSnapshots()
    }

    func updateActiveModules(_ nextModules: ActiveModuleSet) throws {
        try simulationQueue.sync {
            if let reason = ModuleCompatibility.incompatibilityReason(for: nextModules, state: currentSimulationState) {
                throw SimulationRuntimeError.incompatibleModules(nextModules, reason)
            }
            let previousModules = activeModules
            let previousOptimization = activeModules.optimization
            activeModules = nextModules
            if previousOptimization != nextModules.optimization {
                needsInteractionPlanRefresh = true
                cachedDefaultInteractionParticleCount = nil
                if nextModules.optimization.name != FixedGridOptimizationModuleRuntime.moduleName {
                    cachedFixedGridTopology = nil
                }
            }
            if nextModules.isPlaybackModuleFamily {
                // Do not eagerly load playback fixtures here.
                // Coordinator startup and module switching call updateActiveModules synchronously.
                // Large fixture IO/decode must stay off this path to keep launch responsive.
                playbackFixture = nil
                needsParticleRebuild = true
                needsInteractionPlanRefresh = true
                cachedDefaultInteractionParticleCount = nil
                cachedFixedGridTopology = nil
                debugHistory.reset()
                clearLeaderCommunicationLog()
            } else if previousModules.isPlaybackModuleFamily {
                playbackFixture = nil
                playbackCurrentSeconds = 0
                playbackLastUptime = nil
            }
            if self.currentSimulationState.transportState == .stopped {
                self.typeMatrixInteractionBuffer = nil
            }
        }
    }

    func updateSimulationState(_ nextState: SimulationViewportState) {
        snapshotLock.lock()
        simulationStateSnapshot = nextState
        snapshotLock.unlock()

        let shouldApplySynchronously = nextState.transportState != .running
        if DispatchQueue.getSpecific(key: simulationQueueKey) != nil {
            applySimulationState(nextState)
        } else if shouldApplySynchronously {
            simulationQueue.sync {
                self.applySimulationState(nextState)
            }
        } else {
            simulationQueue.async {
                self.applySimulationState(nextState)
            }
        }
    }

    private func applySimulationState(_ nextState: SimulationViewportState) {
        if let reason = ModuleCompatibility.incompatibilityReason(for: self.activeModules, state: nextState) {
            if nextState.transportState == .running || nextState.transportState == .paused {
                return
            }
            assertionFailure("SimulationRuntime received incompatible state: \(reason)")
        }

        let previous = currentSimulationState
        currentSimulationState = nextState
        let playbackSelectionChanged =
            previous.playbackFrontLayerVisible != nextState.playbackFrontLayerVisible
            || previous.playbackMiddleLayerVisible != nextState.playbackMiddleLayerVisible
            || previous.playbackFinalLayerVisible != nextState.playbackFinalLayerVisible
            || previous.playbackFrontLayerSlot != nextState.playbackFrontLayerSlot
            || previous.playbackMiddleLayerSlot != nextState.playbackMiddleLayerSlot
            || previous.playbackFinalLayerSlot != nextState.playbackFinalLayerSlot
        let shouldRebuildParticles =
            previous.particleCount != nextState.particleCount
            || previous.randomDistribution != nextState.randomDistribution
            || previous.particleTypes != nextState.particleTypes
        let optimizationTopologyChanged =
            previous.fixedGridSubdivisions != nextState.fixedGridSubdivisions
            || previous.fixedGridSubspaceCap != nextState.fixedGridSubspaceCap
        let optimizationReadModeChanged =
            previous.fixedGridNeighborReadMode != nextState.fixedGridNeighborReadMode

        if nextState.transportState == .stopped {
            simulationWorkInFlight = false
            tickingSuspended = false
            playbackCurrentSeconds = 0
            playbackLastUptime = nil
            idleCallbacks.removeAll(keepingCapacity: false)
            abandonEphemeralState()
        } else {
            if shouldRebuildParticles {
                needsParticleRebuild = true
                needsInteractionPlanRefresh = true
                cachedDefaultInteractionParticleCount = nil
            }

            if optimizationTopologyChanged {
                cachedFixedGridTopology = nil
                needsInteractionPlanRefresh = true
            }

            if optimizationReadModeChanged {
                needsInteractionPlanRefresh = true
            }

            if previous.showOptimizationInfo && !nextState.showOptimizationInfo {
                debugHistory.reset()
            }

            if previous.showLeaderCommunicationLog && !nextState.showLeaderCommunicationLog {
                clearLeaderCommunicationLog()
            }

            if previous.allParticlesIntercommunicate && !nextState.allParticlesIntercommunicate {
                debugHistory.reset()
                clearLeaderCommunicationLog()
            }

            if previous.transportState == .stopped,
               nextState.transportState == .running,
               isTypeMatrixPhysicsActive {
                if typeMatrixLocalSettings.randomizeOnSimulationStart {
                    uploadTypeMatrixInteractionBuffer(
                        from: TypeMatrixLocalPhysicsSettings.makeRandomMatrix()
                    )
                } else {
                    uploadTypeMatrixInteractionBuffer(from: typeMatrixLocalSettings.matrixValues)
                }
            }
        }

        publishSnapshots()
        if activeModules.isPlaybackModuleFamily,
           playbackSelectionChanged,
           currentSimulationState.transportState != .stopped {
            applyPlaybackSeek(playbackCurrentSeconds)
        }
        reconfigureSimulationLoop()
        let stateSummary = InteractionSnapshotFormat.viewport(nextState)
        let renderSummary = InteractionSnapshotFormat.renderState(
            RenderState(
                particleBuffer: particleFrontBuffer,
                activeParticleCount: activeParticleCount,
                particleCapacity: particleCapacity,
                debugLineBuffer: debugLineBuffer,
                debugRenderSegments: debugHistory.renderSegments,
                playbackActivationMinimum: playbackActivationMinimum,
                playbackActivationMaximum: playbackActivationMaximum
            )
        )
        Task { @MainActor in
            InteractionSnapshotRecorder.shared.record(
                event: "runtime.apply_simulation_state",
                details: [
                    "state": stateSummary,
                    "renderState": renderSummary,
                    "simulationWorkInFlight": "\(self.simulationWorkInFlight)",
                ]
            )
        }
    }

    func suspendTicking(onIdle: (@Sendable () -> Void)? = nil) {
        simulationQueue.async {
            self.tickingSuspended = true
            if let onIdle {
                self.idleCallbacks.append(onIdle)
            }
            self.reconfigureSimulationLoop()
            if !self.simulationWorkInFlight {
                self.drainIdleCallbacks()
            }
        }
    }

    func resumeTicking() {
        simulationQueue.async {
            self.tickingSuspended = false
            self.idleCallbacks.removeAll(keepingCapacity: false)
            self.reconfigureSimulationLoop()
            self.publishSnapshots()
        }
    }

    func discardEphemeralState() {
        simulationQueue.async {
            self.tickingSuspended = true
            self.idleCallbacks.removeAll(keepingCapacity: false)
            self.abandonEphemeralState()
            self.reconfigureSimulationLoop()
        }
    }

    func publishFrameMetrics(averageFPS: Double, at now: TimeInterval) {
        simulationQueue.async {
            guard let metrics = self.metricsAccumulator.metricsIfDue(averageFPS: averageFPS, now: now) else { return }

            Task { @MainActor in
                self.metricsSink(metrics)
            }
        }
    }

    private func reconfigureSimulationLoop() {
        switch currentSimulationState.transportState {
        case .running:
            if tickingSuspended {
                stopSimulationLoop()
            } else {
                startSimulationLoopIfNeeded()
            }
        case .paused, .stopped:
            stopSimulationLoop()
        }
    }

    private func startSimulationLoopIfNeeded() {
        guard simulationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: simulationQueue)
        timer.schedule(deadline: .now(), repeating: simulationTickInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stepSimulation(at: ProcessInfo.processInfo.systemUptime)
        }
        simulationTimer = timer
        timer.resume()
    }

    private func stopSimulationLoop() {
        simulationTimer?.cancel()
        simulationTimer = nil
    }

    private func abandonEphemeralState() {
        particleFrontBuffer = nil
        particleBackBuffer = nil
        interactionGroupIndicesBuffer = nil
        interactionRangeOffsetsBuffer = nil
        interactionRangeTargetsBuffer = nil
        interactionRangesBuffer = nil
        interactionIndicesBuffer = nil
        interactionScratchParticlesBuffer = nil
        interactionScratchToCanonicalBuffer = nil
        fixedGridCellCountsBuffer = nil
        fixedGridCellOffsetsBuffer = nil
        fixedGridCellWriteHeadsBuffer = nil
        fixedGridCellScanBufferA = nil
        fixedGridCellScanBufferB = nil
        typeMatrixInteractionBuffer = nil
        typeMatrixSidecarFrontBuffer = nil
        typeMatrixSidecarBackBuffer = nil
        debugLineBuffer = nil
        debugLineSegmentBuffer = nil
        activeParticleCount = 0
        particleCapacity = 0
        debugHistory.reset()
        clearLeaderCommunicationLog()
        metricsAccumulator.reset()
        needsParticleRebuild = true
        needsInteractionPlanRefresh = true
        cachedDefaultInteractionParticleCount = nil
        cachedFixedGridTopology = nil
        publishSnapshots()
    }

    private func stepSimulation(at now: TimeInterval) {
        guard !simulationWorkInFlight else { return }
        if activeModules.isPlaybackModuleFamily {
            stepPlayback(at: now)
            return
        }

        ensureParticleStateBuffers()

        guard currentSimulationState.transportState == .running,
              let particleFrontBuffer,
              let particleBackBuffer,
              activeParticleCount > 0,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            debugHistory.reset()
            publishSnapshots()
            return
        }

        if !isFixedGridOptimizationActive && needsInteractionPlanRefresh {
            refreshInteractionPlanBuffers(using: particleFrontBuffer, particleCount: activeParticleCount)
        }

        let interParticleCommunicationEnabled = currentSimulationState.allParticlesIntercommunicate
        let shouldBuildDebugLines = interParticleCommunicationEnabled && currentSimulationState.showOptimizationInfo
        let shouldRecordLeaderLog = interParticleCommunicationEnabled && currentSimulationState.showLeaderCommunicationLog
        let leaderRangeOffset = 0
        var leaderRangeCount = 0
        var leaderInteractionCount = 0
        var leaderFirstTargetIndex = 0

        if interParticleCommunicationEnabled {
            if isFixedGridOptimizationActive && (shouldBuildDebugLines || shouldRecordLeaderLog) {
                let debugInfo = fixedGridLeaderDebugInfo(
                    particleBuffer: particleFrontBuffer,
                    particleCount: activeParticleCount
                )
                leaderRangeCount = debugInfo.rangeCount
                leaderInteractionCount = debugInfo.interactionCount
                leaderFirstTargetIndex = debugInfo.firstTargetIndex ?? 0
            } else {
                leaderRangeCount = max(0, interactionRangeCount(for: 0))
                leaderInteractionCount = max(0, interactionCount(for: 0))
                leaderFirstTargetIndex = firstInteractionTargetIndex(for: 0) ?? 0
            }
        }

        if isFixedGridOptimizationActive && interParticleCommunicationEnabled {
            let topology = ensureFixedGridInteractionTopology()
            ensureFixedGridWorkingBuffers(topology: topology)
            encodeFixedGridInteractionPlanning(
                into: commandBuffer,
                sourceParticleBuffer: particleFrontBuffer,
                particleCount: activeParticleCount,
                topology: topology
            )
            needsInteractionPlanRefresh = false
        }

        simulationWorkInFlight = true

        if interParticleCommunicationEnabled,
           let interactionGroupIndicesBuffer,
           let interactionRangeOffsetsBuffer,
           let interactionRangeTargetsBuffer,
           let interactionRangesBuffer,
           let interactionIndicesBuffer,
           let physicsEncoder = commandBuffer.makeComputeCommandEncoder() {
            encodePhysicsAccumulate(
                into: physicsEncoder,
                sourceParticleBuffer: particleFrontBuffer,
                destinationParticleBuffer: particleBackBuffer,
                interactionGroupIndicesBuffer: interactionGroupIndicesBuffer,
                interactionRangeOffsetsBuffer: interactionRangeOffsetsBuffer,
                interactionRangeTargetsBuffer: interactionRangeTargetsBuffer,
                interactionRangesBuffer: interactionRangesBuffer,
                interactionIndicesBuffer: interactionIndicesBuffer
            )
        } else {
            zeroParticleImpulseChannel()
        }

        if shouldBuildDebugLines {
            pruneDebugHistory(now: now)
            cacheLeaderSweepSegment(
                sourceParticleIndex: 0,
                interactionCount: leaderInteractionCount,
                now: now
            )
            rebuildDebugRenderSegments()

            if let interactionGroupIndicesBuffer,
               let interactionRangeOffsetsBuffer,
               let interactionRangeTargetsBuffer,
               let interactionRangesBuffer,
               let interactionIndicesBuffer,
               let currentDebugLineBuffer = debugLineBuffer,
               let debugLineSegmentBuffer,
               !debugHistory.renderSegments.isEmpty,
               let debugLineEncoder = commandBuffer.makeComputeCommandEncoder() {
                debugLineEncoder.setComputePipelineState(debugLinePipeline)
                debugLineEncoder.setBuffer(particleFrontBuffer, offset: 0, index: 0)
                debugLineEncoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 1)
                debugLineEncoder.setBuffer(interactionRangeOffsetsBuffer, offset: 0, index: 2)
                debugLineEncoder.setBuffer(interactionRangeTargetsBuffer, offset: 0, index: 3)
                debugLineEncoder.setBuffer(interactionRangesBuffer, offset: 0, index: 4)
                debugLineEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 5)
                if let interactionScratchParticlesBuffer {
                    debugLineEncoder.setBuffer(interactionScratchParticlesBuffer, offset: 0, index: 6)
                } else {
                    debugLineEncoder.setBuffer(particleFrontBuffer, offset: 0, index: 6)
                }
                if let interactionScratchToCanonicalBuffer {
                    debugLineEncoder.setBuffer(interactionScratchToCanonicalBuffer, offset: 0, index: 7)
                } else {
                    debugLineEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 7)
                }
                debugLineEncoder.setBuffer(currentDebugLineBuffer, offset: 0, index: 8)
                var params = SimulationDebugLineParams(
                    segmentCount: UInt32(debugHistory.renderSegments.count),
                    particleCount: UInt32(activeParticleCount),
                    neighborReadMode: activeNeighborReadModeRawValue
                )
                debugLineEncoder.setBytes(&params, length: MemoryLayout<SimulationDebugLineParams>.stride, index: 9)
                debugLineEncoder.setBuffer(debugLineSegmentBuffer, offset: 0, index: 10)
                let vertexCount = max(1, debugHistory.renderSegments.reduce(0) { $0 + $1.vertexCount })
                let threads = MTLSize(width: vertexCount, height: 1, depth: 1)
                let threadgroup = MTLSize(width: min(debugLinePipeline.maxTotalThreadsPerThreadgroup, 64), height: 1, depth: 1)
                debugLineEncoder.dispatchThreads(threads, threadsPerThreadgroup: threadgroup)
                debugLineEncoder.endEncoding()
            }
        } else {
            debugHistory.reset()
        }

        if shouldRecordLeaderLog, leaderInteractionCount > 0 {
            appendLeaderCommunicationLogEntry(
                now: now,
                firstTargetIndex: leaderFirstTargetIndex,
                interactionCount: leaderInteractionCount,
                startWorkItem: UInt64(leaderRangeOffset),
                workItemCount: UInt64(leaderRangeCount)
            )
        } else if currentSimulationState.showLeaderCommunicationLog {
            publishLeaderCommunicationLog()
        }

        if leaderInteractionCount > 0 {
            metricsAccumulator.recordLeaderInteractions(leaderInteractionCount, at: now)
        }

        if let physicsEncoder = commandBuffer.makeComputeCommandEncoder() {
            encodePhysicsApply(
                into: physicsEncoder,
                sourceParticleBuffer: particleFrontBuffer,
                destinationParticleBuffer: particleBackBuffer,
                now: now
            )
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let runtime = self else { return }
            runtime.simulationQueue.async {
                runtime.swapCompletedParticleBuffers()
                runtime.simulationWorkInFlight = false
                runtime.publishSnapshots()
                runtime.drainIdleCallbacks()
            }
        }
        commandBuffer.commit()
    }

    private func stepPlayback(at now: TimeInterval) {
        guard currentSimulationState.transportState == .running else {
            publishSnapshots()
            return
        }

        guard let fixture = playbackFixture ?? MLPlaybackPrototypeFixtureLoader.loadFixture() else {
            playbackLastUptime = now
            publishSnapshots()
            return
        }
        playbackFixture = fixture

        let previousUptime = playbackLastUptime ?? now
        playbackLastUptime = now
        let deltaSeconds = max(0, now - previousUptime) * Double(currentSimulationState.playbackTimeScale)
        playbackCurrentSeconds = advancedPlaybackTime(
            from: playbackCurrentSeconds,
            by: deltaSeconds,
            duration: fixture.durationSeconds
        )

        let selection = currentPlaybackSurfaceSelection()
        let frame = currentSimulationState.playbackInterpolationEnabled
            ? fixture.interpolatedParticles(
                at: playbackCurrentSeconds,
                selection: selection
            )
            : fixture.particles(
                at: playbackCurrentSeconds,
                selection: selection
            )
        uploadPlaybackParticles(frame.particles)
        metricsAccumulator.recordPhysicsStep(at: now)
        publishSnapshots()
    }

    private func advancedPlaybackTime(from currentSeconds: Double, by deltaSeconds: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let nextSeconds = currentSeconds + deltaSeconds
        if nextSeconds <= duration {
            return nextSeconds
        }
        return playbackLooping ? nextSeconds.truncatingRemainder(dividingBy: duration) : duration
    }

    private func uploadPlaybackParticles(_ particles: [ParticleState]) {
        let particles = preparePlaybackParticlesForDisplay(particles)
        var activationMinimum = Float.greatestFiniteMagnitude
        var activationMaximum = -Float.greatestFiniteMagnitude
        for particle in particles {
            let activation = particle.velocity.x
            activationMinimum = min(activationMinimum, activation)
            activationMaximum = max(activationMaximum, activation)
        }
        if particles.isEmpty || !activationMinimum.isFinite || !activationMaximum.isFinite {
            activationMinimum = 0
            activationMaximum = 1
        } else if activationMinimum == activationMaximum {
            activationMaximum = activationMinimum + 0.0001
        }
        playbackActivationMinimum = activationMinimum
        playbackActivationMaximum = activationMaximum

        let particleLength = max(1, MemoryLayout<ParticleState>.stride * particles.count)
        if let existing = particleFrontBuffer, existing.length >= particleLength {
            let pointer = existing.contents().bindMemory(to: ParticleState.self, capacity: particles.count)
            pointer.update(from: particles, count: particles.count)
            particleFrontBuffer = existing
        } else {
            particleFrontBuffer = device.makeBuffer(bytes: particles, length: particleLength)
        }

        if let existing = particleBackBuffer, existing.length >= particleLength {
            let pointer = existing.contents().bindMemory(to: ParticleState.self, capacity: particles.count)
            pointer.update(from: particles, count: particles.count)
            particleBackBuffer = existing
        } else {
            particleBackBuffer = device.makeBuffer(bytes: particles, length: particleLength)
        }

        activeParticleCount = particles.count
        particleCapacity = (particleFrontBuffer?.length ?? 0) / MemoryLayout<ParticleState>.stride
        debugHistory.reset()
        needsParticleRebuild = false
        needsInteractionPlanRefresh = false
        cachedDefaultInteractionParticleCount = nil
        cachedFixedGridTopology = nil
    }

    private func preparePlaybackParticlesForDisplay(_ particles: [ParticleState]) -> [ParticleState] {
        guard currentSimulationState.isPlaybackVisualModule, !particles.isEmpty else {
            return particles
        }

        var preparedParticles = particles
        let surfaceParticleCount: Int? = {
            let selectedSurfaceCount = currentPlaybackSurfaceSelection().count
            if selectedSurfaceCount > 0, particles.count % selectedSurfaceCount == 0 {
                return particles.count / selectedSurfaceCount
            }
            if particles.count % 15 == 0 {
                return particles.count / 15
            }
            return nil
        }()
        guard let surfaceParticleCount, surfaceParticleCount > 0 else {
            return preparedParticles
        }

        let surfaceHeightScale: Float = 0.72
        let surfaceCount = max(1, particles.count / surfaceParticleCount)
        for surfaceIndex in 0..<surfaceCount {
            let surfaceStart = surfaceIndex * surfaceParticleCount
            let surfaceEnd = min(particles.count, surfaceStart + surfaceParticleCount)
            guard surfaceStart < surfaceEnd else { continue }

            var rawMinimum = Float.greatestFiniteMagnitude
            var rawMaximum = -Float.greatestFiniteMagnitude
            for index in surfaceStart..<surfaceEnd {
                let rawActivation = particles[index].velocity.x
                rawMinimum = min(rawMinimum, rawActivation)
                rawMaximum = max(rawMaximum, rawActivation)
            }
            let rawMidpoint = (rawMinimum + rawMaximum) * 0.5
            let rawHalfRange = max(0.000001, (rawMaximum - rawMinimum) * 0.5)

            var mean: Float = 0
            for index in surfaceStart..<surfaceEnd {
                let height: Float
                switch currentSimulationState.mlPlaybackNormalizationMode {
                case .global:
                    height = particles[index].position.z
                case .perFrame:
                    height = ((particles[index].velocity.x - rawMidpoint) / rawHalfRange) * surfaceHeightScale
                }
                preparedParticles[index].position.z = height
                mean += height
            }
            mean /= Float(max(1, surfaceEnd - surfaceStart))

            var maxCenteredMagnitude: Float = 0.000001
            for index in surfaceStart..<surfaceEnd {
                let centeredHeight = preparedParticles[index].position.z - mean
                preparedParticles[index].position.z = centeredHeight
                maxCenteredMagnitude = max(maxCenteredMagnitude, abs(centeredHeight))
            }

            let normalizationScale = surfaceHeightScale / maxCenteredMagnitude
            for index in surfaceStart..<surfaceEnd {
                preparedParticles[index].position.z *= normalizationScale
            }
        }

        return preparedParticles
    }

    private func currentPlaybackSurfaceSelection() -> [MLPlaybackSurfaceSelection] {
        var selection: [MLPlaybackSurfaceSelection] = []
        if currentSimulationState.playbackFrontLayerVisible {
            selection.append(
                MLPlaybackSurfaceSelection(
                    layer: 0,
                    slot: min(max(0, currentSimulationState.playbackFrontLayerSlot), 4)
                )
            )
        }
        if currentSimulationState.playbackMiddleLayerVisible {
            selection.append(
                MLPlaybackSurfaceSelection(
                    layer: 1,
                    slot: min(max(0, currentSimulationState.playbackMiddleLayerSlot), 4)
                )
            )
        }
        if currentSimulationState.playbackFinalLayerVisible {
            selection.append(
                MLPlaybackSurfaceSelection(
                    layer: 2,
                    slot: min(max(0, currentSimulationState.playbackFinalLayerSlot), 4)
                )
            )
        }
        return selection
    }

    private func encodePhysicsAccumulate(
        into physicsEncoder: MTLComputeCommandEncoder,
        sourceParticleBuffer: MTLBuffer,
        destinationParticleBuffer: MTLBuffer,
        interactionGroupIndicesBuffer: MTLBuffer,
        interactionRangeOffsetsBuffer: MTLBuffer,
        interactionRangeTargetsBuffer: MTLBuffer,
        interactionRangesBuffer: MTLBuffer,
        interactionIndicesBuffer: MTLBuffer
    ) {
        let scratchParticlesBuffer = interactionScratchParticlesBuffer ?? sourceParticleBuffer
        let scratchToCanonicalBuffer = interactionScratchToCanonicalBuffer ?? interactionIndicesBuffer

        if isTypeMatrixPhysicsActive {
            guard let typeMatrixInteractionBuffer else {
                zeroParticleImpulseChannel()
                physicsEncoder.endEncoding()
                return
            }
            guard let sidecarFrontBuffer = typeMatrixSidecarFrontBuffer,
                  let sidecarBackBuffer = typeMatrixSidecarBackBuffer else {
                zeroParticleImpulseChannel()
                physicsEncoder.endEncoding()
                return
            }

            physicsEncoder.setComputePipelineState(typeMatrixPhysicsAccumulatePipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            physicsEncoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 2)
            physicsEncoder.setBuffer(interactionRangeOffsetsBuffer, offset: 0, index: 3)
            physicsEncoder.setBuffer(interactionRangeTargetsBuffer, offset: 0, index: 4)
            physicsEncoder.setBuffer(interactionRangesBuffer, offset: 0, index: 5)
            physicsEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 6)
            physicsEncoder.setBuffer(scratchParticlesBuffer, offset: 0, index: 7)
            physicsEncoder.setBuffer(scratchToCanonicalBuffer, offset: 0, index: 8)
            physicsEncoder.setBuffer(typeMatrixInteractionBuffer, offset: 0, index: 9)
            physicsEncoder.setBuffer(sidecarFrontBuffer, offset: 0, index: 10)
            physicsEncoder.setBuffer(sidecarBackBuffer, offset: 0, index: 11)
            var params = TypeMatrixPhysicsAccumulateParams(
                particleCount: UInt32(activeParticleCount),
                particleTypeCount: UInt32(max(1, currentSimulationState.particleTypes)),
                neighborReadMode: activeNeighborReadModeRawValue,
                innerRadius: Float(typeMatrixLocalSettings.innerRadiusWorldUnits),
                middleRadius: Float(typeMatrixLocalSettings.middleRadiusWorldUnits),
                outerRadius: Float(typeMatrixLocalSettings.outerRadiusWorldUnits),
                attractionMultiplier: Float(typeMatrixLocalSettings.attractionMultiplier),
                repulsionMultiplier: Float(typeMatrixLocalSettings.repulsionMultiplier),
                matrixSideLength: UInt32(TypeMatrixLocalPhysicsSettings.maxParticleTypes),
                teleportationEnabled: typeMatrixLocalSettings.teleportationEnabled ? 1 : 0,
                teleportationGeneralBudget: UInt32(typeMatrixLocalSettings.teleportationGeneralInteractionBudget),
                teleportationSelfBudget: UInt32(typeMatrixLocalSettings.teleportationSelfInteractionBudgetLinked
                    ? typeMatrixLocalSettings.teleportationGeneralInteractionBudget
                    : typeMatrixLocalSettings.teleportationSelfInteractionBudget),
                teleportationSelfBudgetLinked: typeMatrixLocalSettings.teleportationSelfInteractionBudgetLinked ? 1 : 0,
                teleportationAccumulation: Float(typeMatrixLocalSettings.teleportationAccumulation),
                teleportationRecoveryRate: Float(typeMatrixLocalSettings.teleportationRecoveryRate)
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TypeMatrixPhysicsAccumulateParams>.stride, index: 12)
            let threadsPerGroup = MTLSize(
                width: min(typeMatrixPhysicsAccumulatePipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
                height: 1,
                depth: 1
            )
            let threadCount = MTLSize(width: activeParticleCount, height: 1, depth: 1)
            physicsEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
            physicsEncoder.endEncoding()
            return
        }

        if isTemplatePhysicsActive {
            physicsEncoder.setComputePipelineState(templatePhysicsAccumulatePipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            physicsEncoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 2)
            physicsEncoder.setBuffer(interactionRangeOffsetsBuffer, offset: 0, index: 3)
            physicsEncoder.setBuffer(interactionRangeTargetsBuffer, offset: 0, index: 4)
            physicsEncoder.setBuffer(interactionRangesBuffer, offset: 0, index: 5)
            physicsEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 6)
            physicsEncoder.setBuffer(scratchParticlesBuffer, offset: 0, index: 7)
            physicsEncoder.setBuffer(scratchToCanonicalBuffer, offset: 0, index: 8)
            var params = TemplatePhysicsAccumulateParams(
                particleCount: UInt32(activeParticleCount),
                interactionRadius: 0.18,
                impulseScale: 0.004,
                neighborReadMode: activeNeighborReadModeRawValue
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TemplatePhysicsAccumulateParams>.stride, index: 9)
            let threadsPerGroup = MTLSize(
                width: min(templatePhysicsAccumulatePipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
                height: 1,
                depth: 1
            )
            let threadCount = MTLSize(width: activeParticleCount, height: 1, depth: 1)
            physicsEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
            physicsEncoder.endEncoding()
            return
        }

        physicsEncoder.setComputePipelineState(defaultPhysicsAccumulatePipeline)
        physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
        physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
        physicsEncoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 2)
        physicsEncoder.setBuffer(interactionRangeOffsetsBuffer, offset: 0, index: 3)
        physicsEncoder.setBuffer(interactionRangeTargetsBuffer, offset: 0, index: 4)
        physicsEncoder.setBuffer(interactionRangesBuffer, offset: 0, index: 5)
        physicsEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 6)
        physicsEncoder.setBuffer(scratchParticlesBuffer, offset: 0, index: 7)
        physicsEncoder.setBuffer(scratchToCanonicalBuffer, offset: 0, index: 8)
        var params = SimulationPhysicsAccumulateParams(
            particleCount: UInt32(activeParticleCount),
            interactionRadius: 0.42,
            impulseScale: 0.018 * currentSimulationState.timeScale,
            neighborReadMode: activeNeighborReadModeRawValue
        )
        physicsEncoder.setBytes(&params, length: MemoryLayout<SimulationPhysicsAccumulateParams>.stride, index: 9)
        let threadsPerGroup = MTLSize(
            width: min(defaultPhysicsAccumulatePipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
            height: 1,
            depth: 1
        )
        let threadCount = MTLSize(width: activeParticleCount, height: 1, depth: 1)
        physicsEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
        physicsEncoder.endEncoding()
    }

    private func encodePhysicsApply(
        into physicsEncoder: MTLComputeCommandEncoder,
        sourceParticleBuffer: MTLBuffer,
        destinationParticleBuffer: MTLBuffer,
        now: TimeInterval
    ) {
        if isTypeMatrixPhysicsActive {
            guard let typeMatrixSidecarBackBuffer else {
                physicsEncoder.endEncoding()
                return
            }
            physicsEncoder.setComputePipelineState(typeMatrixPhysicsApplyPipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            physicsEncoder.setBuffer(typeMatrixSidecarBackBuffer, offset: 0, index: 2)
            var params = TypeMatrixPhysicsApplyParams(
                particleCount: UInt32(activeParticleCount),
                deltaTime: fixedTimeStep * currentSimulationState.timeScale,
                dampingEnabled: typeMatrixLocalSettings.dampingEnabled ? 1 : 0,
                momentumEnabled: typeMatrixLocalSettings.momentumEnabled ? 1 : 0,
                speedLimitEnabled: typeMatrixLocalSettings.speedLimitEnabled ? 1 : 0,
                dampingStrength: Float(typeMatrixLocalSettings.dampingStrength),
                momentumStrength: Float(typeMatrixLocalSettings.momentumStrength),
                speedLimit: Float(typeMatrixLocalSettings.speedLimit),
                teleportationEnabled: typeMatrixLocalSettings.teleportationEnabled ? 1 : 0,
                teleportationMinimumDistance: Float(typeMatrixLocalSettings.teleportationMinimumDistanceWorldUnits)
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TypeMatrixPhysicsApplyParams>.stride, index: 3)
            let threadsPerGroup = MTLSize(
                width: min(typeMatrixPhysicsApplyPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
                height: 1,
                depth: 1
            )
            let threadCount = MTLSize(width: activeParticleCount, height: 1, depth: 1)
            physicsEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
            physicsEncoder.endEncoding()
        } else if isTemplatePhysicsActive {
            physicsEncoder.setComputePipelineState(templatePhysicsApplyPipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            var params = TemplatePhysicsApplyParams(
                particleCount: UInt32(activeParticleCount),
                deltaTime: fixedTimeStep * currentSimulationState.timeScale,
                velocityDamping: 0.985
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TemplatePhysicsApplyParams>.stride, index: 2)
            let threadsPerGroup = MTLSize(
                width: min(templatePhysicsApplyPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
                height: 1,
                depth: 1
            )
            let threadCount = MTLSize(width: activeParticleCount, height: 1, depth: 1)
            physicsEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
            physicsEncoder.endEncoding()
        } else {
            physicsEncoder.setComputePipelineState(defaultPhysicsApplyPipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            var params = SimulationPhysicsApplyParams(
                movementDirection: SIMD4<Float>(
                    currentSimulationState.movementDirection.x,
                    currentSimulationState.movementDirection.y,
                    currentSimulationState.movementDirection.z,
                    0
                ),
                particleCount: UInt32(activeParticleCount),
                deltaTime: fixedTimeStep * currentSimulationState.timeScale,
                velocityDamping: 0
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<SimulationPhysicsApplyParams>.stride, index: 2)
            let threadsPerGroup = MTLSize(
                width: min(defaultPhysicsApplyPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
                height: 1,
                depth: 1
            )
            let threadCount = MTLSize(width: activeParticleCount, height: 1, depth: 1)
            physicsEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
            physicsEncoder.endEncoding()
        }
        metricsAccumulator.recordPhysicsStep(at: now)
    }

    private func appendLeaderCommunicationLogEntry(
        now: TimeInterval,
        firstTargetIndex: Int,
        interactionCount: Int,
        startWorkItem: UInt64,
        workItemCount: UInt64
    ) {
        let entry = LeaderCommunicationLogEntry(
            recordedAt: String(format: "%.3f", now),
            firstTargetIndex: firstTargetIndex,
            interactionCount: interactionCount,
            workItemStart: startWorkItem,
            workItemCount: workItemCount
        )
        leaderCommunicationLogEntries.append(entry)
        if leaderCommunicationLogEntries.count > 160 {
            leaderCommunicationLogEntries.removeFirst(leaderCommunicationLogEntries.count - 160)
        }
        publishLeaderCommunicationLog()
    }

    private func publishLeaderCommunicationLog() {
        let entries = leaderCommunicationLogEntries
        Task { @MainActor in
            self.leaderCommunicationLogSink(entries)
        }
    }

    private func clearLeaderCommunicationLog() {
        guard !leaderCommunicationLogEntries.isEmpty else {
            Task { @MainActor in
                self.leaderCommunicationLogSink([])
            }
            return
        }
        leaderCommunicationLogEntries.removeAll(keepingCapacity: false)
        publishLeaderCommunicationLog()
    }

    private func ensureParticleStateBuffers() {
        guard needsParticleRebuild
            || particleFrontBuffer == nil
            || particleBackBuffer == nil
            || interactionGroupIndicesBuffer == nil
            || interactionRangeOffsetsBuffer == nil
            || interactionRangeTargetsBuffer == nil
            || interactionRangesBuffer == nil
            || interactionIndicesBuffer == nil else { return }

        let spawnData = DefaultPhysicsModuleRuntime.rebuildParticles(from: currentSimulationState)
        let particles = spawnData.particles

        let particleLength = max(1, MemoryLayout<ParticleState>.stride * particles.count)
        if let existing = particleFrontBuffer, existing.length >= particleLength {
            let pointer = existing.contents().bindMemory(to: ParticleState.self, capacity: particles.count)
            pointer.update(from: particles, count: particles.count)
            particleFrontBuffer = existing
        } else {
            particleFrontBuffer = device.makeBuffer(bytes: particles, length: particleLength)
        }

        if let existing = particleBackBuffer, existing.length >= particleLength {
            let pointer = existing.contents().bindMemory(to: ParticleState.self, capacity: particles.count)
            pointer.update(from: particles, count: particles.count)
            particleBackBuffer = existing
        } else {
            particleBackBuffer = device.makeBuffer(bytes: particles, length: particleLength)
        }

        let sidecarLength = max(1, MemoryLayout<TypeMatrixLocalSidecarState>.stride * particles.count)
        let zeroSidecar = Array(repeating: TypeMatrixLocalSidecarState.zero, count: particles.count)
        if let existing = typeMatrixSidecarFrontBuffer, existing.length >= sidecarLength {
            let pointer = existing.contents().bindMemory(to: TypeMatrixLocalSidecarState.self, capacity: particles.count)
            pointer.update(from: zeroSidecar, count: particles.count)
            typeMatrixSidecarFrontBuffer = existing
        } else {
            typeMatrixSidecarFrontBuffer = device.makeBuffer(bytes: zeroSidecar, length: sidecarLength)
        }

        if let existing = typeMatrixSidecarBackBuffer, existing.length >= sidecarLength {
            let pointer = existing.contents().bindMemory(to: TypeMatrixLocalSidecarState.self, capacity: particles.count)
            pointer.update(from: zeroSidecar, count: particles.count)
            typeMatrixSidecarBackBuffer = existing
        } else {
            typeMatrixSidecarBackBuffer = device.makeBuffer(bytes: zeroSidecar, length: sidecarLength)
        }

        activeParticleCount = spawnData.activeCount
        particleCapacity = (particleFrontBuffer?.length ?? 0) / MemoryLayout<ParticleState>.stride
        if let particleFrontBuffer {
            if isFixedGridOptimizationActive {
                let topology = ensureFixedGridInteractionTopology()
                ensureFixedGridWorkingBuffers(topology: topology)
            } else {
                refreshInteractionPlanBuffers(using: particleFrontBuffer, particleCount: activeParticleCount)
            }
        }
        debugHistory.reset()
        needsParticleRebuild = false

        let maxDebugLineVertices = max(2, activeParticleCount * 2 * debugHistorySegmentCapacity)
        let lineBufferLength = MemoryLayout<SimulationLineVertex>.stride * maxDebugLineVertices
        if debugLineBuffer == nil || debugLineBuffer?.length ?? 0 < lineBufferLength {
            debugLineBuffer = device.makeBuffer(length: lineBufferLength)
        }
        let segmentBufferLength = MemoryLayout<SimulationDebugLineSegment>.stride * debugHistorySegmentCapacity
        if debugLineSegmentBuffer == nil || debugLineSegmentBuffer?.length ?? 0 < segmentBufferLength {
            debugLineSegmentBuffer = device.makeBuffer(length: segmentBufferLength)
        }
    }

    private func publishSnapshots() {
        let renderState = RenderState(
            particleBuffer: particleFrontBuffer,
            activeParticleCount: activeParticleCount,
            particleCapacity: particleCapacity,
            debugLineBuffer: debugLineBuffer,
            debugRenderSegments: debugHistory.renderSegments,
            playbackActivationMinimum: playbackActivationMinimum,
            playbackActivationMaximum: playbackActivationMaximum
        )
        let simulationState = currentSimulationState

        snapshotLock.lock()
        renderStateSnapshot = renderState
        simulationStateSnapshot = simulationState
        snapshotLock.unlock()
    }

    private func drainIdleCallbacks() {
        guard !simulationWorkInFlight else { return }
        let callbacks = idleCallbacks
        idleCallbacks.removeAll(keepingCapacity: false)
        for callback in callbacks {
            callback()
        }
    }

    private func cacheLeaderSweepSegment(
        sourceParticleIndex: Int,
        interactionCount: Int,
        now: TimeInterval
    ) {
        guard interactionCount > 0 else { return }
        debugHistory.cacheSegment(
            sourceParticleIndex: sourceParticleIndex,
            interactionCount: interactionCount,
            startedAt: now
        )
    }

    private func refreshInteractionPlanBuffers(using particleBuffer: MTLBuffer, particleCount: Int) {
        guard needsInteractionPlanRefresh || cachedDefaultInteractionParticleCount != particleCount else {
            return
        }
        let interactionPlan = DefaultOptimizationModuleRuntime.rebuildInteractionPlan(particleCount: particleCount)
        uploadInteractionPlanBuffers(interactionPlan)
        cachedDefaultInteractionParticleCount = particleCount
        needsInteractionPlanRefresh = false
    }

    private func ensureFixedGridInteractionTopology() -> FixedGridInteractionTopology {
        let settings = FixedGridOptimizationSettings(
            subdivisions: currentSimulationState.fixedGridSubdivisions,
            subspaceCap: currentSimulationState.fixedGridSubspaceCap,
            neighborReadMode: .raw
        )
        if let cachedFixedGridTopology, cachedFixedGridTopology.settings == settings {
            return cachedFixedGridTopology
        }
        let topology = FixedGridOptimizationModuleRuntime.buildInteractionTopology(settings: settings)
        cachedFixedGridTopology = topology
        uploadFixedGridTopologyBuffers(topology)
        return topology
    }

    private func ensureFixedGridWorkingBuffers(topology: FixedGridInteractionTopology) {
        let cellCount = max(1, topology.rangeOffsets.count - 1)
        let particleSlotCount = max(1, particleCapacity)

        let cellCountsLength = max(1, MemoryLayout<UInt32>.stride * cellCount)
        if fixedGridCellCountsBuffer == nil || fixedGridCellCountsBuffer?.length ?? 0 < cellCountsLength {
            fixedGridCellCountsBuffer = device.makeBuffer(length: cellCountsLength)
        }

        let cellOffsetsLength = max(1, MemoryLayout<UInt32>.stride * (cellCount + 1))
        if fixedGridCellOffsetsBuffer == nil || fixedGridCellOffsetsBuffer?.length ?? 0 < cellOffsetsLength {
            fixedGridCellOffsetsBuffer = device.makeBuffer(length: cellOffsetsLength)
        }

        let cellWriteHeadsLength = max(1, MemoryLayout<UInt32>.stride * cellCount)
        if fixedGridCellWriteHeadsBuffer == nil || fixedGridCellWriteHeadsBuffer?.length ?? 0 < cellWriteHeadsLength {
            fixedGridCellWriteHeadsBuffer = device.makeBuffer(length: cellWriteHeadsLength)
        }

        let cellScanLength = max(1, MemoryLayout<UInt32>.stride * cellCount)
        if fixedGridCellScanBufferA == nil || fixedGridCellScanBufferA?.length ?? 0 < cellScanLength {
            fixedGridCellScanBufferA = device.makeBuffer(length: cellScanLength)
        }
        if fixedGridCellScanBufferB == nil || fixedGridCellScanBufferB?.length ?? 0 < cellScanLength {
            fixedGridCellScanBufferB = device.makeBuffer(length: cellScanLength)
        }

        let groupIndicesLength = max(1, MemoryLayout<UInt32>.stride * particleSlotCount)
        if interactionGroupIndicesBuffer == nil || interactionGroupIndicesBuffer?.length ?? 0 < groupIndicesLength {
            interactionGroupIndicesBuffer = device.makeBuffer(length: groupIndicesLength)
        }

        let rangesLength = max(1, MemoryLayout<InteractionRangeEntry>.stride * cellCount)
        if interactionRangesBuffer == nil || interactionRangesBuffer?.length ?? 0 < rangesLength {
            interactionRangesBuffer = device.makeBuffer(length: rangesLength)
        }

        let indicesLength = max(1, MemoryLayout<UInt32>.stride * particleSlotCount)
        if interactionIndicesBuffer == nil || interactionIndicesBuffer?.length ?? 0 < indicesLength {
            interactionIndicesBuffer = device.makeBuffer(length: indicesLength)
        }

        if activeFixedGridNeighborReadMode == .scratch {
            let scratchParticlesLength = max(1, MemoryLayout<ParticleState>.stride * particleSlotCount)
            if interactionScratchParticlesBuffer == nil || interactionScratchParticlesBuffer?.length ?? 0 < scratchParticlesLength {
                interactionScratchParticlesBuffer = device.makeBuffer(length: scratchParticlesLength)
            }

            let scratchToCanonicalLength = max(1, MemoryLayout<UInt32>.stride * particleSlotCount)
            if interactionScratchToCanonicalBuffer == nil || interactionScratchToCanonicalBuffer?.length ?? 0 < scratchToCanonicalLength {
                interactionScratchToCanonicalBuffer = device.makeBuffer(length: scratchToCanonicalLength)
            }
        }
    }

    private func encodeFixedGridInteractionPlanning(
        into commandBuffer: MTLCommandBuffer,
        sourceParticleBuffer: MTLBuffer,
        particleCount: Int,
        topology: FixedGridInteractionTopology
    ) {
        guard let interactionGroupIndicesBuffer,
              let interactionRangesBuffer,
              let interactionIndicesBuffer,
              let fixedGridCellCountsBuffer,
              let fixedGridCellOffsetsBuffer,
              let fixedGridCellWriteHeadsBuffer,
              let fixedGridCellScanBufferA,
              let fixedGridCellScanBufferB else {
            return
        }

        let cellCount = max(1, topology.rangeOffsets.count - 1)
        var cellParams = FixedGridCellCountParams(cellCount: UInt32(cellCount))
        var assignParams = FixedGridAssignParticlesParams(
            particleCount: UInt32(particleCount),
            subdivisions: UInt32(topology.settings.clampedSubdivisions),
            neighborReadMode: activeNeighborReadModeRawValue
        )

        let cellThreads = MTLSize(width: cellCount, height: 1, depth: 1)
        let cellThreadgroup = MTLSize(
            width: min(fixedGridClearCellCountsPipeline.maxTotalThreadsPerThreadgroup, 256),
            height: 1,
            depth: 1
        )
        if let clearEncoder = commandBuffer.makeComputeCommandEncoder() {
            clearEncoder.setComputePipelineState(fixedGridClearCellCountsPipeline)
            clearEncoder.setBuffer(fixedGridCellCountsBuffer, offset: 0, index: 0)
            clearEncoder.setBytes(&cellParams, length: MemoryLayout<FixedGridCellCountParams>.stride, index: 1)
            clearEncoder.dispatchThreads(cellThreads, threadsPerThreadgroup: cellThreadgroup)
            clearEncoder.endEncoding()
        }

        let particleThreads = MTLSize(width: particleCount, height: 1, depth: 1)
        let particleThreadgroup = MTLSize(
            width: min(fixedGridAssignParticlesPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
            height: 1,
            depth: 1
        )
        if let assignEncoder = commandBuffer.makeComputeCommandEncoder() {
            assignEncoder.setComputePipelineState(fixedGridAssignParticlesPipeline)
            assignEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            assignEncoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 1)
            assignEncoder.setBuffer(fixedGridCellCountsBuffer, offset: 0, index: 2)
            assignEncoder.setBytes(&assignParams, length: MemoryLayout<FixedGridAssignParticlesParams>.stride, index: 3)
            assignEncoder.dispatchThreads(particleThreads, threadsPerThreadgroup: particleThreadgroup)
            assignEncoder.endEncoding()
        }

        if let rangesEncoder = commandBuffer.makeComputeCommandEncoder() {
            rangesEncoder.setComputePipelineState(fixedGridPrepareGroupRangesPipeline)
            rangesEncoder.setBuffer(fixedGridCellCountsBuffer, offset: 0, index: 0)
            rangesEncoder.setBuffer(fixedGridCellScanBufferA, offset: 0, index: 1)
            rangesEncoder.setBytes(&cellParams, length: MemoryLayout<FixedGridCellCountParams>.stride, index: 2)
            rangesEncoder.dispatchThreads(cellThreads, threadsPerThreadgroup: cellThreadgroup)
            rangesEncoder.endEncoding()
        }

        var scanInputBuffer = fixedGridCellScanBufferA
        var scanOutputBuffer = fixedGridCellScanBufferB
        var stride = 1
        while stride < cellCount {
            var scanParams = FixedGridScanStepParams(
                cellCount: UInt32(cellCount),
                stride: UInt32(stride)
            )
            if let scanEncoder = commandBuffer.makeComputeCommandEncoder() {
                scanEncoder.setComputePipelineState(fixedGridScanGroupRangesPipeline)
                scanEncoder.setBuffer(scanInputBuffer, offset: 0, index: 0)
                scanEncoder.setBuffer(scanOutputBuffer, offset: 0, index: 1)
                scanEncoder.setBytes(&scanParams, length: MemoryLayout<FixedGridScanStepParams>.stride, index: 2)
                scanEncoder.dispatchThreads(cellThreads, threadsPerThreadgroup: cellThreadgroup)
                scanEncoder.endEncoding()
            }
            swap(&scanInputBuffer, &scanOutputBuffer)
            stride <<= 1
        }

        if let finalizeEncoder = commandBuffer.makeComputeCommandEncoder() {
            finalizeEncoder.setComputePipelineState(fixedGridFinalizeGroupRangesPipeline)
            finalizeEncoder.setBuffer(fixedGridCellCountsBuffer, offset: 0, index: 0)
            finalizeEncoder.setBuffer(scanInputBuffer, offset: 0, index: 1)
            finalizeEncoder.setBuffer(fixedGridCellOffsetsBuffer, offset: 0, index: 2)
            finalizeEncoder.setBuffer(fixedGridCellWriteHeadsBuffer, offset: 0, index: 3)
            finalizeEncoder.setBuffer(interactionRangesBuffer, offset: 0, index: 4)
            finalizeEncoder.setBytes(&cellParams, length: MemoryLayout<FixedGridCellCountParams>.stride, index: 5)
            finalizeEncoder.dispatchThreads(MTLSize(width: cellCount + 1, height: 1, depth: 1), threadsPerThreadgroup: cellThreadgroup)
            finalizeEncoder.endEncoding()
        }

        if let scatterEncoder = commandBuffer.makeComputeCommandEncoder() {
            scatterEncoder.setComputePipelineState(fixedGridScatterParticleIndicesPipeline)
            scatterEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            scatterEncoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 1)
            scatterEncoder.setBuffer(fixedGridCellWriteHeadsBuffer, offset: 0, index: 2)
            scatterEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 3)
            if let interactionScratchParticlesBuffer {
                scatterEncoder.setBuffer(interactionScratchParticlesBuffer, offset: 0, index: 4)
            } else {
                scatterEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 4)
            }
            if let interactionScratchToCanonicalBuffer {
                scatterEncoder.setBuffer(interactionScratchToCanonicalBuffer, offset: 0, index: 5)
            } else {
                scatterEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 5)
            }
            scatterEncoder.setBytes(&assignParams, length: MemoryLayout<FixedGridAssignParticlesParams>.stride, index: 6)
            scatterEncoder.dispatchThreads(particleThreads, threadsPerThreadgroup: particleThreadgroup)
            scatterEncoder.endEncoding()
        }
    }

    private func uploadInteractionPlanBuffers(_ interactionPlan: OptimizationInteractionPlanData) {
        let storedGroupCount = max(1, interactionPlan.groupIndices.count)
        let groupIndicesLength = max(1, MemoryLayout<UInt32>.stride * storedGroupCount)
        if let existing = interactionGroupIndicesBuffer, existing.length >= groupIndicesLength {
            let pointer = existing.contents().bindMemory(to: UInt32.self, capacity: storedGroupCount)
            if interactionPlan.groupIndices.isEmpty {
                pointer[0] = 0
            } else {
                pointer.update(from: interactionPlan.groupIndices, count: interactionPlan.groupIndices.count)
            }
            interactionGroupIndicesBuffer = existing
        } else if interactionPlan.groupIndices.isEmpty {
            var placeholderGroupIndex: UInt32 = 0
            interactionGroupIndicesBuffer = device.makeBuffer(bytes: &placeholderGroupIndex, length: groupIndicesLength)
        } else {
            interactionGroupIndicesBuffer = device.makeBuffer(bytes: interactionPlan.groupIndices, length: groupIndicesLength)
        }

        let rangeOffsetsLength = max(1, MemoryLayout<UInt32>.stride * interactionPlan.rangeOffsets.count)
        if let existing = interactionRangeOffsetsBuffer, existing.length >= rangeOffsetsLength {
            let pointer = existing.contents().bindMemory(to: UInt32.self, capacity: interactionPlan.rangeOffsets.count)
            pointer.update(from: interactionPlan.rangeOffsets, count: interactionPlan.rangeOffsets.count)
            interactionRangeOffsetsBuffer = existing
        } else {
            interactionRangeOffsetsBuffer = device.makeBuffer(bytes: interactionPlan.rangeOffsets, length: rangeOffsetsLength)
        }

        let storedRangeTargetCount = max(1, interactionPlan.rangeTargets.count)
        let rangeTargetsLength = max(1, MemoryLayout<UInt32>.stride * storedRangeTargetCount)
        if let existing = interactionRangeTargetsBuffer, existing.length >= rangeTargetsLength {
            let pointer = existing.contents().bindMemory(to: UInt32.self, capacity: storedRangeTargetCount)
            if interactionPlan.rangeTargets.isEmpty {
                pointer[0] = 0
            } else {
                pointer.update(from: interactionPlan.rangeTargets, count: interactionPlan.rangeTargets.count)
            }
            interactionRangeTargetsBuffer = existing
        } else if interactionPlan.rangeTargets.isEmpty {
            var placeholderRangeTarget: UInt32 = 0
            interactionRangeTargetsBuffer = device.makeBuffer(bytes: &placeholderRangeTarget, length: rangeTargetsLength)
        } else {
            interactionRangeTargetsBuffer = device.makeBuffer(bytes: interactionPlan.rangeTargets, length: rangeTargetsLength)
        }

        let storedRangeCount = max(1, interactionPlan.ranges.count)
        let rangesLength = max(1, MemoryLayout<InteractionRangeEntry>.stride * storedRangeCount)
        if let existing = interactionRangesBuffer, existing.length >= rangesLength {
            let pointer = existing.contents().bindMemory(to: InteractionRangeEntry.self, capacity: storedRangeCount)
            if interactionPlan.ranges.isEmpty {
                pointer[0] = InteractionRangeEntry(startIndex: 0, count: 0)
            } else {
                pointer.update(from: interactionPlan.ranges, count: interactionPlan.ranges.count)
            }
            interactionRangesBuffer = existing
        } else if interactionPlan.ranges.isEmpty {
            var placeholderRange = InteractionRangeEntry(startIndex: 0, count: 0)
            interactionRangesBuffer = device.makeBuffer(bytes: &placeholderRange, length: rangesLength)
        } else {
            interactionRangesBuffer = device.makeBuffer(bytes: interactionPlan.ranges, length: rangesLength)
        }

        let storedIndexCount = max(1, interactionPlan.indices.count)
        let indicesLength = max(1, MemoryLayout<UInt32>.stride * storedIndexCount)
        if let existing = interactionIndicesBuffer, existing.length >= indicesLength {
            let pointer = existing.contents().bindMemory(to: UInt32.self, capacity: storedIndexCount)
            if interactionPlan.indices.isEmpty {
                pointer[0] = 0
            } else {
                pointer.update(from: interactionPlan.indices, count: interactionPlan.indices.count)
            }
            interactionIndicesBuffer = existing
        } else if interactionPlan.indices.isEmpty {
            var placeholderIndex: UInt32 = 0
            interactionIndicesBuffer = device.makeBuffer(bytes: &placeholderIndex, length: indicesLength)
        } else {
            interactionIndicesBuffer = device.makeBuffer(bytes: interactionPlan.indices, length: indicesLength)
        }
    }

    private func uploadFixedGridTopologyBuffers(_ topology: FixedGridInteractionTopology) {
        let rangeOffsetsLength = max(1, MemoryLayout<UInt32>.stride * topology.rangeOffsets.count)
        if let existing = interactionRangeOffsetsBuffer, existing.length >= rangeOffsetsLength {
            let pointer = existing.contents().bindMemory(to: UInt32.self, capacity: topology.rangeOffsets.count)
            pointer.update(from: topology.rangeOffsets, count: topology.rangeOffsets.count)
            interactionRangeOffsetsBuffer = existing
        } else {
            interactionRangeOffsetsBuffer = device.makeBuffer(bytes: topology.rangeOffsets, length: rangeOffsetsLength)
        }

        let storedRangeTargetCount = max(1, topology.rangeTargets.count)
        let rangeTargetsLength = max(1, MemoryLayout<UInt32>.stride * storedRangeTargetCount)
        if let existing = interactionRangeTargetsBuffer, existing.length >= rangeTargetsLength {
            let pointer = existing.contents().bindMemory(to: UInt32.self, capacity: storedRangeTargetCount)
            if topology.rangeTargets.isEmpty {
                pointer[0] = 0
            } else {
                pointer.update(from: topology.rangeTargets, count: topology.rangeTargets.count)
            }
            interactionRangeTargetsBuffer = existing
        } else if topology.rangeTargets.isEmpty {
            var placeholderRangeTarget: UInt32 = 0
            interactionRangeTargetsBuffer = device.makeBuffer(bytes: &placeholderRangeTarget, length: rangeTargetsLength)
        } else {
            interactionRangeTargetsBuffer = device.makeBuffer(bytes: topology.rangeTargets, length: rangeTargetsLength)
        }
    }

    private struct FixedGridLeaderDebugInfo {
        var rangeCount: Int
        var interactionCount: Int
        var firstTargetIndex: Int?
    }

    private func fixedGridLeaderDebugInfo(
        particleBuffer: MTLBuffer,
        particleCount: Int
    ) -> FixedGridLeaderDebugInfo {
        guard particleCount > 0 else {
            return FixedGridLeaderDebugInfo(rangeCount: 0, interactionCount: 0, firstTargetIndex: nil)
        }

        let topology = ensureFixedGridInteractionTopology()
        let leaderRangeCount = max(0, Int(topology.rangeOffsets[1]) - Int(topology.rangeOffsets[0]))
        let particles = particleBuffer.contents().bindMemory(to: ParticleState.self, capacity: particleCount)
        let leader = particles[0]
        guard leader.active != 0 else {
            return FixedGridLeaderDebugInfo(rangeCount: leaderRangeCount, interactionCount: 0, firstTargetIndex: nil)
        }

        let leaderCellIndex = FixedGridOptimizationModuleRuntime.cellIndex(
            for: leader.position,
            settings: topology.settings
        )
        let rangeStart = Int(topology.rangeOffsets[leaderCellIndex])
        let rangeEnd = Int(topology.rangeOffsets[leaderCellIndex + 1])
        var targetGroups: Set<Int> = []
        targetGroups.reserveCapacity(max(1, rangeEnd - rangeStart))
        for rangeIndex in rangeStart..<rangeEnd {
            targetGroups.insert(Int(topology.rangeTargets[rangeIndex]))
        }

        var interactionCount = 0
        var firstTargetIndex: Int?
        for particleIndex in 0..<particleCount {
            let particle = particles[particleIndex]
            guard particle.active != 0 else { continue }
            let cellIndex = FixedGridOptimizationModuleRuntime.cellIndex(
                for: particle.position,
                settings: topology.settings
            )
            guard targetGroups.contains(cellIndex) else { continue }
            interactionCount += 1
            if firstTargetIndex == nil {
                firstTargetIndex = particleIndex
            }
        }

        return FixedGridLeaderDebugInfo(
            rangeCount: rangeEnd - rangeStart,
            interactionCount: interactionCount,
            firstTargetIndex: firstTargetIndex
        )
    }

    private func interactionRangeCount(for particleIndex: Int) -> Int {
        guard let interactionGroupIndicesBuffer,
              let interactionRangeOffsetsBuffer,
              particleIndex >= 0,
              particleIndex < activeParticleCount else {
            return 0
        }
        let groups = interactionGroupIndicesBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: activeParticleCount
        )
        let groupIndex = Int(groups[particleIndex])
        let offsets = interactionRangeOffsetsBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride
        )
        guard groupIndex + 1 < interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride else {
            return 0
        }
        return max(0, Int(offsets[groupIndex + 1]) - Int(offsets[groupIndex]))
    }

    private func interactionCount(for particleIndex: Int) -> Int {
        guard let interactionGroupIndicesBuffer,
              let interactionRangeOffsetsBuffer,
              let interactionRangeTargetsBuffer,
              let interactionRangesBuffer,
              particleIndex >= 0,
              particleIndex < activeParticleCount else {
            return 0
        }
        let groups = interactionGroupIndicesBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: activeParticleCount
        )
        let groupIndex = Int(groups[particleIndex])
        let offsets = interactionRangeOffsetsBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride
        )
        guard groupIndex + 1 < interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride else {
            return 0
        }
        let rangeStart = Int(offsets[groupIndex])
        let rangeEnd = Int(offsets[groupIndex + 1])
        guard rangeEnd > rangeStart else { return 0 }
        let rangeTargets = interactionRangeTargetsBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: interactionRangeTargetsBuffer.length / MemoryLayout<UInt32>.stride
        )
        let ranges = interactionRangesBuffer.contents().bindMemory(
            to: InteractionRangeEntry.self,
            capacity: interactionRangesBuffer.length / MemoryLayout<InteractionRangeEntry>.stride
        )
        var count = 0
        for rangeIndex in rangeStart..<rangeEnd {
            let targetGroupIndex = Int(rangeTargets[rangeIndex])
            count += Int(ranges[targetGroupIndex].count)
        }
        return count
    }

    private func firstInteractionTargetIndex(for particleIndex: Int) -> Int? {
        guard let interactionGroupIndicesBuffer,
              let interactionRangeOffsetsBuffer,
              let interactionRangeTargetsBuffer,
              let interactionRangesBuffer,
              let interactionIndicesBuffer,
              particleIndex >= 0,
              particleIndex < activeParticleCount else {
            return nil
        }
        let groups = interactionGroupIndicesBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: activeParticleCount
        )
        let groupIndex = Int(groups[particleIndex])
        let offsets = interactionRangeOffsetsBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride
        )
        guard groupIndex + 1 < interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride else {
            return nil
        }
        let rangeStart = Int(offsets[groupIndex])
        let rangeEnd = Int(offsets[groupIndex + 1])
        guard rangeEnd > rangeStart else { return nil }
        let rangeTargets = interactionRangeTargetsBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: interactionRangeTargetsBuffer.length / MemoryLayout<UInt32>.stride
        )
        let ranges = interactionRangesBuffer.contents().bindMemory(
            to: InteractionRangeEntry.self,
            capacity: interactionRangesBuffer.length / MemoryLayout<InteractionRangeEntry>.stride
        )
        let indices = interactionIndicesBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: interactionIndicesBuffer.length / MemoryLayout<UInt32>.stride
        )
        for rangeIndex in rangeStart..<rangeEnd {
            let targetGroupIndex = Int(rangeTargets[rangeIndex])
            let range = ranges[targetGroupIndex]
            guard range.count > 0 else { continue }
            let targetIndex = Int(indices[Int(range.startIndex)])
            if activeFixedGridNeighborReadMode == .scratch,
               let interactionScratchToCanonicalBuffer {
                let reverse = interactionScratchToCanonicalBuffer.contents().bindMemory(
                    to: UInt32.self,
                    capacity: interactionScratchToCanonicalBuffer.length / MemoryLayout<UInt32>.stride
                )
                guard targetIndex < interactionScratchToCanonicalBuffer.length / MemoryLayout<UInt32>.stride else {
                    return nil
                }
                return Int(reverse[targetIndex])
            }
            return targetIndex
        }
        return nil
    }

    private func pruneDebugHistory(now: TimeInterval) {
        debugHistory.prune(now: now)
    }

    private func rebuildDebugRenderSegments() {
        debugHistory.rebuildRenderSegments(into: debugLineSegmentBuffer)
    }

    private func zeroParticleImpulseChannel() {
        guard let particleBackBuffer, activeParticleCount > 0 else { return }
        let particles = particleBackBuffer.contents().bindMemory(to: ParticleState.self, capacity: activeParticleCount)
        for index in 0..<activeParticleCount {
            particles[index].impulse = .zero
        }
    }

    private func swapCompletedParticleBuffers() {
        let previousFront = particleFrontBuffer
        particleFrontBuffer = particleBackBuffer
        particleBackBuffer = previousFront

        let previousTypeMatrixSidecarFront = typeMatrixSidecarFrontBuffer
        typeMatrixSidecarFrontBuffer = typeMatrixSidecarBackBuffer
        typeMatrixSidecarBackBuffer = previousTypeMatrixSidecarFront
    }

    private var isTypeMatrixPhysicsActive: Bool {
        activeModules.physics.name == TypeMatrixLocalPhysicsSettings.moduleName
    }

    private var isTemplatePhysicsActive: Bool {
        activeModules.physics.name == PhysicsModuleTemplateRuntime.moduleName
    }

    private var isFixedGridOptimizationActive: Bool {
        activeModules.optimization.name == FixedGridOptimizationModuleRuntime.moduleName
    }

    private var activeFixedGridNeighborReadMode: FixedGridNeighborReadMode {
        guard isFixedGridOptimizationActive else { return .raw }
        return currentSimulationState.fixedGridNeighborReadMode
    }

    private var activeNeighborReadModeRawValue: UInt32 {
        switch activeFixedGridNeighborReadMode {
        case .raw:
            return 0
        case .scratch:
            return 1
        }
    }

    private func uploadTypeMatrixInteractionBuffer(from sourceMatrix: [Int]) {
        let matrix = sourceMatrix.map(Int32.init)
        let length = max(1, MemoryLayout<Int32>.stride * matrix.count)
        // Never mutate the live GPU matrix buffer in place. Swapping in a fresh buffer
        // lets in-flight command buffers keep their old snapshot safely.
        typeMatrixInteractionBuffer = device.makeBuffer(bytes: matrix, length: length)
    }
}
