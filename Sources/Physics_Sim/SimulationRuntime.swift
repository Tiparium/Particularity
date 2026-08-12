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

private struct PrimordialSoupLifecycleRelationshipGPU {
    var signedForce: Float
    var energyCost: Float
    var threatContribution: Float
    var reserved0: Float = 0
}

private struct PrimordialSoupLifecycleTypeProfileGPU {
    var maxSpeed: Float
    var motility: Float
    var innerRadius: Float
    var middleRadius: Float
    var outerRadius: Float
    var energyDecayRate: Float
    var reproductionEnergyThreshold: Float
    var reproductionEnergyCost: Float
    var childEnergyFraction: Float
    var reproductionCooldown: Float
    var threatSensitivity: Float
    var reserved0: Float = 0
}

private struct PrimordialSoupLifecycleSidecarState {
    var energy: Float
    var age: Float
    var reproductionCooldownRemaining: Float
    var interactionEnergyDelta: Float

    static let inactive = PrimordialSoupLifecycleSidecarState(
        energy: 0,
        age: 0,
        reproductionCooldownRemaining: 0,
        interactionEnergyDelta: 0
    )
}

private struct PrimordialSoupLifecycleSpawnRecord {
    var particle: ParticleState
    var sidecar: PrimordialSoupLifecycleSidecarState
    var targetSlot: UInt32
    var reserved0: UInt32 = 0
    var reserved1: UInt32 = 0
    var reserved2: UInt32 = 0
}

private struct PrimordialSoupLifecycleAccumulateParams {
    var particleCount: UInt32
    var particleTypeCount: UInt32
    var neighborReadMode: UInt32
    var padding0: UInt32 = 0
    var innerRadiusMultiplier: Float
    var middleRadiusMultiplier: Float
    var outerRadiusMultiplier: Float
    var attractionMultiplier: Float
    var repulsionMultiplier: Float
}

private struct PrimordialSoupLifecycleApplyParams {
    var particleCount: UInt32
    var particleTypeCount: UInt32
    var initialActiveCount: UInt32
    var spawnRecordCapacity: UInt32
    var randomSeed: UInt32
    var deltaTime: Float
    var dampingEnabled: UInt32
    var momentumEnabled: UInt32
    var speedLimitEnabled: UInt32
    var dampingStrength: Float
    var momentumStrength: Float
    var speedLimit: Float
}

private struct PrimordialSoupLifecycleSpawnResolveParams {
    var particleCount: UInt32
    var spawnRecordCapacity: UInt32
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

struct SimulationDebugLineSegment {
    var sourceParticleIndex: UInt32
    var interactionCount: UInt32
    var firstVertexIndex: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
    var padding3: UInt32 = 0
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

        var particlePositionBuffer: MTLBuffer? { particleBuffer }
        var particleColorBuffer: MTLBuffer? { nil }
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let commandQueue: MTLCommandQueue
    private let defaultPhysicsAccumulatePipeline: MTLComputePipelineState
    private let defaultPhysicsApplyPipeline: MTLComputePipelineState
    private let templatePhysicsAccumulatePipeline: MTLComputePipelineState
    private let templatePhysicsApplyPipeline: MTLComputePipelineState
    private let typeMatrixPhysicsAccumulatePipeline: MTLComputePipelineState
    private let typeMatrixPhysicsApplyPipeline: MTLComputePipelineState
    private let primordialSoupLifecycleAccumulatePipeline: MTLComputePipelineState
    private let primordialSoupLifecycleApplyPipeline: MTLComputePipelineState
    private let primordialSoupLifecycleResolveSpawnsPipeline: MTLComputePipelineState
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

    private var simulationTimer: DispatchSourceTimer?
    private var simulationWorkInFlight = false
    private var tickingSuspended = false
    private var idleCallbacks: [@Sendable () -> Void] = []

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
    private var primordialSoupLifecycleRelationshipBuffer: MTLBuffer?
    private var primordialSoupLifecycleTypeProfileBuffer: MTLBuffer?
    private var primordialSoupLifecycleSidecarFrontBuffer: MTLBuffer?
    private var primordialSoupLifecycleSidecarBackBuffer: MTLBuffer?
    private var primordialSoupLifecycleSpawnRecordsBuffer: MTLBuffer?
    private var primordialSoupLifecycleFrameSpawnCounterBuffer: MTLBuffer?
    private var primordialSoupLifecycleNextSpawnSlotCounterBuffer: MTLBuffer?
    private var primordialSoupLifecycleInitialActiveCount = 0
    private var primordialSoupLifecycleSpawnRecordCapacity = 0
    private var primordialSoupLifecycleFrameIndex: UInt32 = 0
    private var customStandardPhysicsModuleID: String?
    private var customStandardPhysicsAccumulatePipeline: MTLComputePipelineState?
    private var customStandardPhysicsApplyPipeline: MTLComputePipelineState?
    private var toyPlaybackRuntime: ToyPlaybackRuntime?
    private var mlPlaybackRuntime: MLPlaybackRuntime?
    private var mlPlaybackRuntimeLoadAttempted = false
    private var playbackCurrentSeconds: Double = 0
    private var playbackLastUptime: TimeInterval?
    private var playbackCurrentSampleIndex: Int?
    private var debugLineBuffer: MTLBuffer?
    private var debugLineSegmentBuffer: MTLBuffer?
    private var activeParticleCount = 0
    private var particleCapacity = 0
    private var debugHistory = SimulationDebugHistory(historyCapacity: 8, visibilityDuration: 0.11)
    private var leaderCommunicationLogEntries: [LeaderCommunicationLogEntry] = []
    private var needsParticleRebuild = true
    private var needsInteractionPlanRefresh = true
    private var cachedDefaultInteractionParticleCount: Int?
    private var cachedFixedGridTopology: FixedGridInteractionTopology?
    private var typeMatrixLocalSettings = TypeMatrixLocalPhysicsSettings()
    private var primordialSoupLifecycleSettings = PrimordialSoupLifecycleSettings()
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
        showLeaderCommunicationLog: false,
        playbackRate: 1.0,
        playbackLooping: true,
        mlPlayback: MLPlaybackViewportSettings(),
        fixedGridSubdivisions: FixedGridOptimizationModuleRuntime.defaultSubdivisions,
        fixedGridSubspaceCap: 2,
        fixedGridNeighborReadMode: .scratch
    )
    private var activeModules = ActiveModuleSet(
        physics: ModuleCatalog.defaultPhysics,
        visual: ModuleCatalog.defaultVisual,
        optimization: ModuleCatalog.defaultOptimization
    )

    private var renderStateSnapshot = RenderState(
        particleBuffer: nil,
        activeParticleCount: 0,
        particleCapacity: 0,
        debugLineBuffer: nil,
        debugRenderSegments: []
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
        showLeaderCommunicationLog: false,
        playbackRate: 1.0,
        playbackLooping: true,
        mlPlayback: MLPlaybackViewportSettings(),
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
        guard let primordialSoupLifecycleAccumulateFunction = library.makeFunction(name: "primordial_soup_lifecycle_accumulate_impulse") else {
            throw SimulationRuntimeError.missingFunction("primordial_soup_lifecycle_accumulate_impulse")
        }
        guard let primordialSoupLifecycleApplyFunction = library.makeFunction(name: "primordial_soup_lifecycle_apply_impulse") else {
            throw SimulationRuntimeError.missingFunction("primordial_soup_lifecycle_apply_impulse")
        }
        guard let primordialSoupLifecycleResolveSpawnsFunction = library.makeFunction(name: "primordial_soup_lifecycle_resolve_spawns") else {
            throw SimulationRuntimeError.missingFunction("primordial_soup_lifecycle_resolve_spawns")
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
            self.primordialSoupLifecycleAccumulatePipeline = try device.makeComputePipelineState(function: primordialSoupLifecycleAccumulateFunction)
            self.primordialSoupLifecycleApplyPipeline = try device.makeComputePipelineState(function: primordialSoupLifecycleApplyFunction)
            self.primordialSoupLifecycleResolveSpawnsPipeline = try device.makeComputePipelineState(function: primordialSoupLifecycleResolveSpawnsFunction)
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
            } else if description.contains("primordial_soup_lifecycle_accumulate_impulse") {
                failingName = "primordial_soup_lifecycle_accumulate_impulse"
            } else if description.contains("primordial_soup_lifecycle_apply_impulse") {
                failingName = "primordial_soup_lifecycle_apply_impulse"
            } else if description.contains("primordial_soup_lifecycle_resolve_spawns") {
                failingName = "primordial_soup_lifecycle_resolve_spawns"
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
        self.library = library
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

    var playbackTimelineState: PlaybackTimelineState {
        simulationQueue.sync {
            makePlaybackTimelineState()
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

    func updatePrimordialSoupLifecycleSettings(_ nextSettings: PrimordialSoupLifecycleSettings) {
        simulationQueue.async {
            self.primordialSoupLifecycleSettings = nextSettings
            RuntimeEventLogger.log(
                "primordial_soup_lifecycle runtime_update nonce=\(nextSettings.regenerationNonce) transport=\(self.currentSimulationState.transportState.rawValue) active=\(self.isPrimordialSoupLifecyclePhysicsActive)"
            )
            guard self.isPrimordialSoupLifecyclePhysicsActive else {
                return
            }
            self.uploadPrimordialSoupLifecycleBehaviorSpace(nextSettings.activeBehaviorSpace)
        }
    }

    func updateActiveModules(_ nextModules: ActiveModuleSet) throws {
        try simulationQueue.sync {
            if let reason = ModuleCompatibility.incompatibilityReason(for: nextModules, state: currentSimulationState) {
                throw SimulationRuntimeError.incompatibleModules(nextModules, reason)
            }
            let previousModules = activeModules
            let previousOptimization = activeModules.optimization
            let customPhysicsPipelines = try makeCustomStandardPhysicsPipelinesIfNeeded(for: nextModules.physics)
            activeModules = nextModules
            customStandardPhysicsModuleID = customPhysicsPipelines?.moduleID
            customStandardPhysicsAccumulatePipeline = customPhysicsPipelines?.accumulatePipeline
            customStandardPhysicsApplyPipeline = customPhysicsPipelines?.applyPipeline
            if previousOptimization != nextModules.optimization {
                needsInteractionPlanRefresh = true
                cachedDefaultInteractionParticleCount = nil
                if nextModules.optimization.name != FixedGridOptimizationModuleRuntime.moduleName {
                    cachedFixedGridTopology = nil
                }
            }
            if previousModules.executionModel != nextModules.executionModel
                || previousModules.completeModuleFamilyID != nextModules.completeModuleFamilyID {
                toyPlaybackRuntime = nil
                mlPlaybackRuntime = nil
                mlPlaybackRuntimeLoadAttempted = false
                playbackCurrentSeconds = 0
                playbackLastUptime = nil
                playbackCurrentSampleIndex = nil
                abandonEphemeralState()
            }
            if self.currentSimulationState.transportState == .stopped {
                self.typeMatrixInteractionBuffer = nil
                self.primordialSoupLifecycleRelationshipBuffer = nil
                self.primordialSoupLifecycleTypeProfileBuffer = nil
                self.primordialSoupLifecycleSidecarFrontBuffer = nil
                self.primordialSoupLifecycleSidecarBackBuffer = nil
                self.primordialSoupLifecycleSpawnRecordsBuffer = nil
                self.primordialSoupLifecycleFrameSpawnCounterBuffer = nil
                self.primordialSoupLifecycleNextSpawnSlotCounterBuffer = nil
                self.primordialSoupLifecycleInitialActiveCount = 0
                self.primordialSoupLifecycleSpawnRecordCapacity = 0
                self.primordialSoupLifecycleFrameIndex = 0
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

    func seekPlayback(to seconds: Double) {
        simulationQueue.async {
            guard self.isPlaybackRuntimeActive,
                  self.currentSimulationState.transportState != .stopped else {
                return
            }
            guard let playbackRuntime = self.ensureActivePlaybackRuntime() else {
                return
            }
            self.playbackCurrentSeconds = min(max(0, seconds), playbackRuntime.timeline.durationSeconds)
            self.playbackLastUptime = nil
            let frame = playbackRuntime.frame(at: self.playbackCurrentSeconds)
            self.playbackCurrentSampleIndex = frame.sampleIndex
            self.uploadPlaybackParticles(frame.particles)
            self.publishSnapshots()
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

            if previous.transportState == .stopped,
               nextState.transportState == .running,
               isPrimordialSoupLifecyclePhysicsActive {
                uploadPrimordialSoupLifecycleBehaviorSpace(primordialSoupLifecycleSettings.activeBehaviorSpace)
            }

            if isPlaybackRuntimeActive {
                if previous.transportState == .stopped,
                   nextState.transportState == .running {
                    playbackCurrentSeconds = 0
                    playbackCurrentSampleIndex = nil
                }
                if nextState.transportState == .running,
                   previous.transportState != .running {
                    playbackLastUptime = nil
                }
            }
        }

        publishSnapshots()
        reconfigureSimulationLoop()
        let stateSummary = InteractionSnapshotFormat.viewport(nextState)
        let renderSummary = InteractionSnapshotFormat.renderState(
            RenderState(
                particleBuffer: particleFrontBuffer,
                activeParticleCount: activeParticleCount,
                particleCapacity: particleCapacity,
                debugLineBuffer: debugLineBuffer,
                debugRenderSegments: debugHistory.renderSegments
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
        toyPlaybackRuntime = nil
        mlPlaybackRuntime = nil
        primordialSoupLifecycleRelationshipBuffer = nil
        primordialSoupLifecycleTypeProfileBuffer = nil
        primordialSoupLifecycleSidecarFrontBuffer = nil
        primordialSoupLifecycleSidecarBackBuffer = nil
        primordialSoupLifecycleSpawnRecordsBuffer = nil
        primordialSoupLifecycleFrameSpawnCounterBuffer = nil
        primordialSoupLifecycleNextSpawnSlotCounterBuffer = nil
        primordialSoupLifecycleInitialActiveCount = 0
        primordialSoupLifecycleSpawnRecordCapacity = 0
        primordialSoupLifecycleFrameIndex = 0
        mlPlaybackRuntimeLoadAttempted = false
        playbackCurrentSeconds = 0
        playbackLastUptime = nil
        playbackCurrentSampleIndex = nil
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
        if isPlaybackRuntimeActive {
            stepPlayback(at: now)
            return
        }
        guard ensureParticleStateBuffers() else { return }

        guard currentSimulationState.transportState == .running,
              let particleFrontBuffer,
              let particleBackBuffer,
              activeParticleCount > 0,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            debugHistory.reset()
            publishSnapshots()
            return
        }
        simulationWorkInFlight = true

        if isFixedGridOptimizationActive {
            let topology = ensureFixedGridInteractionTopology()
            ensureFixedGridWorkingBuffers(topology: topology)
            encodeFixedGridInteractionPlanning(
                into: commandBuffer,
                sourceParticleBuffer: particleFrontBuffer,
                particleCount: activeParticleCount,
                topology: topology
            )
            needsInteractionPlanRefresh = false
        } else {
            refreshInteractionPlanBuffers(using: particleFrontBuffer, particleCount: activeParticleCount)
        }

        let interParticleCommunicationEnabled = currentSimulationState.allParticlesIntercommunicate
        let shouldBuildDebugLines = interParticleCommunicationEnabled && currentSimulationState.showOptimizationInfo
        let shouldRecordLeaderLog = interParticleCommunicationEnabled && currentSimulationState.showLeaderCommunicationLog
        let leaderInteractionCount = interParticleCommunicationEnabled ? interactionCount(for: 0) : 0
        let leaderFirstTargetIndex = firstInteractionTargetIndex(for: 0) ?? 0

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
                debugLineEncoder.setBuffer(interactionScratchParticlesBuffer ?? particleFrontBuffer, offset: 0, index: 6)
                debugLineEncoder.setBuffer(interactionScratchToCanonicalBuffer ?? interactionIndicesBuffer, offset: 0, index: 7)
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
                startWorkItem: 0,
                workItemCount: UInt64(leaderInteractionCount)
            )
        } else if currentSimulationState.showLeaderCommunicationLog {
            publishLeaderCommunicationLog()
        }

        if leaderInteractionCount > 0 {
            metricsAccumulator.recordLeaderInteractions(leaderInteractionCount, at: now)
        }

        if isPrimordialSoupLifecyclePhysicsActive {
            resetPrimordialSoupLifecycleFrameSpawnCounter(in: commandBuffer)
        }

        if let physicsEncoder = commandBuffer.makeComputeCommandEncoder() {
            encodePhysicsApply(
                into: physicsEncoder,
                sourceParticleBuffer: particleFrontBuffer,
                destinationParticleBuffer: particleBackBuffer,
                now: now
            )
        }

        if isPrimordialSoupLifecyclePhysicsActive,
           let spawnResolveEncoder = commandBuffer.makeComputeCommandEncoder() {
            encodePrimordialSoupLifecycleSpawnResolve(
                into: spawnResolveEncoder,
                destinationParticleBuffer: particleBackBuffer
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
        simulationWorkInFlight = true
        defer { simulationWorkInFlight = false }

        guard let playbackRuntime = ensureActivePlaybackRuntime() else {
            publishSnapshots()
            return
        }

        let previousUptime = playbackLastUptime ?? now
        playbackLastUptime = now
        let deltaSeconds = max(0, now - previousUptime) * Double(currentSimulationState.playbackRate)
        playbackCurrentSeconds = advancedPlaybackTime(
            from: playbackCurrentSeconds,
            by: deltaSeconds,
            duration: playbackRuntime.timeline.durationSeconds,
            looping: currentSimulationState.playbackLooping
        )

        if let mlPlaybackRuntime = playbackRuntime as? MLPlaybackRuntime {
            mlPlaybackRuntime.updateSettings(currentSimulationState.mlPlayback)
        }

        let frame = playbackRuntime.frame(at: playbackCurrentSeconds)
        playbackCurrentSampleIndex = frame.sampleIndex
        uploadPlaybackParticles(frame.particles)
        metricsAccumulator.recordPhysicsStep(at: now)
        publishSnapshots()
    }

    private func ensureActivePlaybackRuntime() -> ParticlePlaybackRuntime? {
        if isToyPlaybackActive {
            return ensureToyPlaybackRuntime()
        }
        if isMLPlaybackActive {
            return ensureMLPlaybackRuntime()
        }
        return nil
    }

    private func ensureToyPlaybackRuntime() -> ToyPlaybackRuntime {
        if let toyPlaybackRuntime {
            return toyPlaybackRuntime
        }

        let runtime = ToyPlaybackRuntime()
        toyPlaybackRuntime = runtime
        RuntimeEventLogger.log(
            "toy_playback loaded duration=\(String(format: "%.3f", runtime.timeline.durationSeconds)) samples=\(runtime.timeline.sampleCount ?? 0)"
        )
        return runtime
    }

    private func ensureMLPlaybackRuntime() -> MLPlaybackRuntime? {
        if let mlPlaybackRuntime {
            return mlPlaybackRuntime
        }
        guard !mlPlaybackRuntimeLoadAttempted else {
            return nil
        }
        mlPlaybackRuntimeLoadAttempted = true

        guard let runtime = MLPlaybackRuntime() else {
            return nil
        }
        mlPlaybackRuntime = runtime
        RuntimeEventLogger.log(
            "ml_playback loaded duration=\(String(format: "%.3f", runtime.timeline.durationSeconds)) samples=\(runtime.timeline.sampleCount ?? 0)"
        )
        return runtime
    }

    private func makePlaybackTimelineState() -> PlaybackTimelineState {
        guard isPlaybackRuntimeActive else { return PlaybackTimelineState() }
        let base = ensureActivePlaybackRuntime()?.timeline ?? PlaybackTimelineState()
        return PlaybackTimelineState(
            currentSeconds: playbackCurrentSeconds,
            durationSeconds: base.durationSeconds,
            playbackRate: Double(currentSimulationState.playbackRate),
            isLooping: currentSimulationState.playbackLooping,
            sampleCount: base.sampleCount,
            currentSampleIndex: playbackCurrentSampleIndex
        )
    }

    private func advancedPlaybackTime(
        from currentSeconds: Double,
        by deltaSeconds: Double,
        duration: Double,
        looping: Bool
    ) -> Double {
        guard duration > 0 else { return 0 }
        let nextSeconds = currentSeconds + deltaSeconds
        if nextSeconds < duration {
            return max(0, nextSeconds)
        }
        return looping ? nextSeconds.truncatingRemainder(dividingBy: duration) : duration
    }

    private func uploadPlaybackParticles(_ particles: [ParticleState]) {
        let particleCount = particles.count
        let particleLength = max(1, MemoryLayout<ParticleState>.stride * particleCount)
        if let existing = particleFrontBuffer, existing.length >= particleLength {
            let pointer = existing.contents().bindMemory(to: ParticleState.self, capacity: particleCount)
            if !particles.isEmpty {
                pointer.update(from: particles, count: particleCount)
            }
            particleFrontBuffer = existing
        } else if particles.isEmpty {
            particleFrontBuffer = device.makeBuffer(length: particleLength)
        } else {
            particleFrontBuffer = device.makeBuffer(bytes: particles, length: particleLength)
        }

        particleBackBuffer = nil
        activeParticleCount = particleCount
        particleCapacity = (particleFrontBuffer?.length ?? 0) / MemoryLayout<ParticleState>.stride
        debugHistory.reset()
        clearLeaderCommunicationLog()
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
            physicsEncoder.setBuffer(interactionScratchParticlesBuffer ?? sourceParticleBuffer, offset: 0, index: 7)
            physicsEncoder.setBuffer(interactionScratchToCanonicalBuffer ?? interactionIndicesBuffer, offset: 0, index: 8)
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

        if isPrimordialSoupLifecyclePhysicsActive {
            guard let relationshipBuffer = primordialSoupLifecycleRelationshipBuffer,
                  let typeProfileBuffer = primordialSoupLifecycleTypeProfileBuffer,
                  let lifecycleSidecarFrontBuffer = primordialSoupLifecycleSidecarFrontBuffer,
                  let lifecycleSidecarBackBuffer = primordialSoupLifecycleSidecarBackBuffer else {
                zeroParticleImpulseChannel()
                physicsEncoder.endEncoding()
                return
            }
            physicsEncoder.setComputePipelineState(primordialSoupLifecycleAccumulatePipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            physicsEncoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 2)
            physicsEncoder.setBuffer(interactionRangeOffsetsBuffer, offset: 0, index: 3)
            physicsEncoder.setBuffer(interactionRangeTargetsBuffer, offset: 0, index: 4)
            physicsEncoder.setBuffer(interactionRangesBuffer, offset: 0, index: 5)
            physicsEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 6)
            physicsEncoder.setBuffer(interactionScratchParticlesBuffer ?? sourceParticleBuffer, offset: 0, index: 7)
            physicsEncoder.setBuffer(interactionScratchToCanonicalBuffer ?? interactionIndicesBuffer, offset: 0, index: 8)
            physicsEncoder.setBuffer(relationshipBuffer, offset: 0, index: 9)
            physicsEncoder.setBuffer(typeProfileBuffer, offset: 0, index: 10)
            physicsEncoder.setBuffer(lifecycleSidecarFrontBuffer, offset: 0, index: 11)
            physicsEncoder.setBuffer(lifecycleSidecarBackBuffer, offset: 0, index: 12)
            var params = PrimordialSoupLifecycleAccumulateParams(
                particleCount: UInt32(activeParticleCount),
                particleTypeCount: UInt32(max(1, primordialSoupLifecycleSettings.activeTypeCount)),
                neighborReadMode: activeNeighborReadModeRawValue,
                innerRadiusMultiplier: Float(primordialSoupLifecycleSettings.innerRadiusMultiplier),
                middleRadiusMultiplier: Float(primordialSoupLifecycleSettings.middleRadiusMultiplier),
                outerRadiusMultiplier: Float(primordialSoupLifecycleSettings.outerRadiusMultiplier),
                attractionMultiplier: Float(primordialSoupLifecycleSettings.attractionMultiplier),
                repulsionMultiplier: Float(primordialSoupLifecycleSettings.repulsionMultiplier)
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<PrimordialSoupLifecycleAccumulateParams>.stride, index: 13)
            let threadsPerGroup = MTLSize(
                width: min(primordialSoupLifecycleAccumulatePipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
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
            physicsEncoder.setBuffer(interactionScratchParticlesBuffer ?? sourceParticleBuffer, offset: 0, index: 7)
            physicsEncoder.setBuffer(interactionScratchToCanonicalBuffer ?? interactionIndicesBuffer, offset: 0, index: 8)
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

        if isCustomStandardPhysicsActive,
           let accumulatePipeline = customStandardPhysicsAccumulatePipeline {
            physicsEncoder.setComputePipelineState(accumulatePipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            physicsEncoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 2)
            physicsEncoder.setBuffer(interactionRangeOffsetsBuffer, offset: 0, index: 3)
            physicsEncoder.setBuffer(interactionRangeTargetsBuffer, offset: 0, index: 4)
            physicsEncoder.setBuffer(interactionRangesBuffer, offset: 0, index: 5)
            physicsEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 6)
            physicsEncoder.setBuffer(interactionScratchParticlesBuffer ?? sourceParticleBuffer, offset: 0, index: 7)
            physicsEncoder.setBuffer(interactionScratchToCanonicalBuffer ?? interactionIndicesBuffer, offset: 0, index: 8)
            var params = TemplatePhysicsAccumulateParams(
                particleCount: UInt32(activeParticleCount),
                interactionRadius: 0.18,
                impulseScale: 0.004,
                neighborReadMode: activeNeighborReadModeRawValue
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TemplatePhysicsAccumulateParams>.stride, index: 9)
            let threadsPerGroup = MTLSize(
                width: min(accumulatePipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
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
        physicsEncoder.setBuffer(interactionScratchParticlesBuffer ?? sourceParticleBuffer, offset: 0, index: 7)
        physicsEncoder.setBuffer(interactionScratchToCanonicalBuffer ?? interactionIndicesBuffer, offset: 0, index: 8)
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
        } else if isPrimordialSoupLifecyclePhysicsActive {
            guard let typeProfileBuffer = primordialSoupLifecycleTypeProfileBuffer,
                  let lifecycleSidecarBackBuffer = primordialSoupLifecycleSidecarBackBuffer,
                  let spawnRecordsBuffer = primordialSoupLifecycleSpawnRecordsBuffer,
                  let frameSpawnCounterBuffer = primordialSoupLifecycleFrameSpawnCounterBuffer,
                  let nextSpawnSlotCounterBuffer = primordialSoupLifecycleNextSpawnSlotCounterBuffer else {
                physicsEncoder.endEncoding()
                return
            }
            physicsEncoder.setComputePipelineState(primordialSoupLifecycleApplyPipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            physicsEncoder.setBuffer(typeProfileBuffer, offset: 0, index: 2)
            physicsEncoder.setBuffer(lifecycleSidecarBackBuffer, offset: 0, index: 3)
            physicsEncoder.setBuffer(spawnRecordsBuffer, offset: 0, index: 4)
            physicsEncoder.setBuffer(frameSpawnCounterBuffer, offset: 0, index: 5)
            physicsEncoder.setBuffer(nextSpawnSlotCounterBuffer, offset: 0, index: 6)
            primordialSoupLifecycleFrameIndex &+= 1
            var params = PrimordialSoupLifecycleApplyParams(
                particleCount: UInt32(activeParticleCount),
                particleTypeCount: UInt32(max(1, primordialSoupLifecycleSettings.activeTypeCount)),
                initialActiveCount: UInt32(primordialSoupLifecycleInitialActiveCount),
                spawnRecordCapacity: UInt32(primordialSoupLifecycleSpawnRecordCapacity),
                randomSeed: primordialSoupLifecycleFrameIndex,
                deltaTime: fixedTimeStep * currentSimulationState.timeScale,
                dampingEnabled: primordialSoupLifecycleSettings.dampingEnabled ? 1 : 0,
                momentumEnabled: primordialSoupLifecycleSettings.momentumEnabled ? 1 : 0,
                speedLimitEnabled: primordialSoupLifecycleSettings.speedLimitEnabled ? 1 : 0,
                dampingStrength: Float(primordialSoupLifecycleSettings.dampingStrength),
                momentumStrength: Float(primordialSoupLifecycleSettings.momentumStrength),
                speedLimit: Float(primordialSoupLifecycleSettings.speedLimit)
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<PrimordialSoupLifecycleApplyParams>.stride, index: 7)
            let threadsPerGroup = MTLSize(
                width: min(primordialSoupLifecycleApplyPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
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
        } else if isCustomStandardPhysicsActive,
                  let applyPipeline = customStandardPhysicsApplyPipeline {
            physicsEncoder.setComputePipelineState(applyPipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            var params = TemplatePhysicsApplyParams(
                particleCount: UInt32(activeParticleCount),
                deltaTime: fixedTimeStep * currentSimulationState.timeScale,
                velocityDamping: 0.985
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TemplatePhysicsApplyParams>.stride, index: 2)
            let threadsPerGroup = MTLSize(
                width: min(applyPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
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

    private func resetPrimordialSoupLifecycleFrameSpawnCounter(in commandBuffer: MTLCommandBuffer) {
        guard let frameSpawnCounterBuffer = primordialSoupLifecycleFrameSpawnCounterBuffer,
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.fill(
            buffer: frameSpawnCounterBuffer,
            range: 0..<MemoryLayout<UInt32>.stride,
            value: 0
        )
        blitEncoder.endEncoding()
    }

    private func encodePrimordialSoupLifecycleSpawnResolve(
        into encoder: MTLComputeCommandEncoder,
        destinationParticleBuffer: MTLBuffer
    ) {
        guard primordialSoupLifecycleSpawnRecordCapacity > 0,
              let lifecycleSidecarBackBuffer = primordialSoupLifecycleSidecarBackBuffer,
              let spawnRecordsBuffer = primordialSoupLifecycleSpawnRecordsBuffer,
              let frameSpawnCounterBuffer = primordialSoupLifecycleFrameSpawnCounterBuffer else {
            encoder.endEncoding()
            return
        }
        encoder.setComputePipelineState(primordialSoupLifecycleResolveSpawnsPipeline)
        encoder.setBuffer(destinationParticleBuffer, offset: 0, index: 0)
        encoder.setBuffer(lifecycleSidecarBackBuffer, offset: 0, index: 1)
        encoder.setBuffer(spawnRecordsBuffer, offset: 0, index: 2)
        encoder.setBuffer(frameSpawnCounterBuffer, offset: 0, index: 3)
        var params = PrimordialSoupLifecycleSpawnResolveParams(
            particleCount: UInt32(activeParticleCount),
            spawnRecordCapacity: UInt32(primordialSoupLifecycleSpawnRecordCapacity)
        )
        encoder.setBytes(&params, length: MemoryLayout<PrimordialSoupLifecycleSpawnResolveParams>.stride, index: 4)
        let threadsPerGroup = MTLSize(
            width: min(primordialSoupLifecycleResolveSpawnsPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup),
            height: 1,
            depth: 1
        )
        let threadCount = MTLSize(width: primordialSoupLifecycleSpawnRecordCapacity, height: 1, depth: 1)
        encoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
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

    private func ensureParticleStateBuffers() -> Bool {
        guard needsParticleRebuild
            || needsInteractionPlanRefresh
            || particleFrontBuffer == nil
            || particleBackBuffer == nil
            || interactionGroupIndicesBuffer == nil
            || interactionRangeOffsetsBuffer == nil
            || interactionRangeTargetsBuffer == nil
            || interactionRangesBuffer == nil
            || interactionIndicesBuffer == nil else { return true }

        let spawnData: DefaultPhysicsModuleRuntime.SpawnData
        if isPrimordialSoupLifecyclePhysicsActive {
            let capacity = max(1, currentSimulationState.particleCount)
            let initialActiveCount = max(
                1,
                min(
                    capacity,
                    Int((Double(capacity) * primordialSoupLifecycleSettings.initialPopulationPercent).rounded())
                )
            )
            primordialSoupLifecycleInitialActiveCount = initialActiveCount
            spawnData = DefaultPhysicsModuleRuntime.rebuildParticles(
                particleCapacity: capacity,
                activeCount: initialActiveCount,
                typeCount: primordialSoupLifecycleSettings.activeTypeCount,
                randomDistribution: primordialSoupLifecycleSettings.randomDistribution
            )
        } else {
            primordialSoupLifecycleInitialActiveCount = 0
            spawnData = DefaultPhysicsModuleRuntime.rebuildParticles(from: currentSimulationState)
        }
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

        if isPrimordialSoupLifecyclePhysicsActive {
            let lifecycleSidecar = particles.map {
                $0.active == 0
                    ? PrimordialSoupLifecycleSidecarState.inactive
                    : PrimordialSoupLifecycleSidecarState(
                        energy: 1,
                        age: 0,
                        reproductionCooldownRemaining: 0,
                        interactionEnergyDelta: 0
                    )
            }
            let lifecycleSidecarLength = max(1, MemoryLayout<PrimordialSoupLifecycleSidecarState>.stride * particles.count)
            if let existing = primordialSoupLifecycleSidecarFrontBuffer, existing.length >= lifecycleSidecarLength {
                let pointer = existing.contents().bindMemory(to: PrimordialSoupLifecycleSidecarState.self, capacity: particles.count)
                pointer.update(from: lifecycleSidecar, count: particles.count)
                primordialSoupLifecycleSidecarFrontBuffer = existing
            } else {
                primordialSoupLifecycleSidecarFrontBuffer = device.makeBuffer(bytes: lifecycleSidecar, length: lifecycleSidecarLength)
            }

            if let existing = primordialSoupLifecycleSidecarBackBuffer, existing.length >= lifecycleSidecarLength {
                let pointer = existing.contents().bindMemory(to: PrimordialSoupLifecycleSidecarState.self, capacity: particles.count)
                pointer.update(from: lifecycleSidecar, count: particles.count)
                primordialSoupLifecycleSidecarBackBuffer = existing
            } else {
                primordialSoupLifecycleSidecarBackBuffer = device.makeBuffer(bytes: lifecycleSidecar, length: lifecycleSidecarLength)
            }

            primordialSoupLifecycleSpawnRecordCapacity = min(max(64, particles.count / 8), 8192)
            let spawnRecordLength = max(
                1,
                MemoryLayout<PrimordialSoupLifecycleSpawnRecord>.stride * primordialSoupLifecycleSpawnRecordCapacity
            )
            if primordialSoupLifecycleSpawnRecordsBuffer == nil
                || (primordialSoupLifecycleSpawnRecordsBuffer?.length ?? 0) < spawnRecordLength {
                primordialSoupLifecycleSpawnRecordsBuffer = device.makeBuffer(length: spawnRecordLength)
            }

            var zeroCounter: UInt32 = 0
            let counterLength = MemoryLayout<UInt32>.stride
            primordialSoupLifecycleFrameSpawnCounterBuffer = device.makeBuffer(bytes: &zeroCounter, length: counterLength)
            primordialSoupLifecycleNextSpawnSlotCounterBuffer = device.makeBuffer(bytes: &zeroCounter, length: counterLength)
            primordialSoupLifecycleFrameIndex = 0
        } else {
            primordialSoupLifecycleSidecarFrontBuffer = nil
            primordialSoupLifecycleSidecarBackBuffer = nil
            primordialSoupLifecycleSpawnRecordsBuffer = nil
            primordialSoupLifecycleFrameSpawnCounterBuffer = nil
            primordialSoupLifecycleNextSpawnSlotCounterBuffer = nil
            primordialSoupLifecycleSpawnRecordCapacity = 0
            primordialSoupLifecycleFrameIndex = 0
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
        return true
    }

    private func publishSnapshots() {
        let renderState = RenderState(
            particleBuffer: particleFrontBuffer,
            activeParticleCount: activeParticleCount,
            particleCapacity: particleCapacity,
            debugLineBuffer: debugLineBuffer,
            debugRenderSegments: debugHistory.renderSegments
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
            neighborReadMode: activeFixedGridNeighborReadMode
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
        } else {
            interactionScratchParticlesBuffer = nil
            interactionScratchToCanonicalBuffer = nil
        }
    }

    private func uploadInteractionPlanBuffers(_ interactionPlan: OptimizationInteractionPlanData) {
        uploadUInt32Buffer(values: interactionPlan.groupIndices, into: &interactionGroupIndicesBuffer)
        uploadUInt32Buffer(values: interactionPlan.rangeOffsets, into: &interactionRangeOffsetsBuffer)
        uploadUInt32Buffer(values: interactionPlan.rangeTargets, into: &interactionRangeTargetsBuffer)

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
            var placeholder = InteractionRangeEntry(startIndex: 0, count: 0)
            interactionRangesBuffer = device.makeBuffer(bytes: &placeholder, length: rangesLength)
        } else {
            interactionRangesBuffer = device.makeBuffer(bytes: interactionPlan.ranges, length: rangesLength)
        }

        uploadUInt32Buffer(values: interactionPlan.indices, into: &interactionIndicesBuffer)
        interactionScratchParticlesBuffer = nil
        interactionScratchToCanonicalBuffer = nil
    }

    private func uploadFixedGridTopologyBuffers(_ topology: FixedGridInteractionTopology) {
        uploadUInt32Buffer(values: topology.rangeOffsets, into: &interactionRangeOffsetsBuffer)
        uploadUInt32Buffer(values: topology.rangeTargets, into: &interactionRangeTargetsBuffer)
    }

    private func uploadUInt32Buffer(values: [UInt32], into buffer: inout MTLBuffer?) {
        let storedCount = max(1, values.count)
        let length = max(1, MemoryLayout<UInt32>.stride * storedCount)
        if let existing = buffer, existing.length >= length {
            let pointer = existing.contents().bindMemory(to: UInt32.self, capacity: storedCount)
            if values.isEmpty {
                pointer[0] = 0
            } else {
                pointer.update(from: values, count: values.count)
            }
            buffer = existing
        } else if values.isEmpty {
            var placeholder: UInt32 = 0
            buffer = device.makeBuffer(bytes: &placeholder, length: length)
        } else {
            buffer = device.makeBuffer(bytes: values, length: length)
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
        let cellThreadgroup = MTLSize(width: min(fixedGridClearCellCountsPipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(fixedGridClearCellCountsPipeline)
            encoder.setBuffer(fixedGridCellCountsBuffer, offset: 0, index: 0)
            encoder.setBytes(&cellParams, length: MemoryLayout<FixedGridCellCountParams>.stride, index: 1)
            encoder.dispatchThreads(cellThreads, threadsPerThreadgroup: cellThreadgroup)
            encoder.endEncoding()
        }

        let particleThreads = MTLSize(width: particleCount, height: 1, depth: 1)
        let particleThreadgroup = MTLSize(width: min(fixedGridAssignParticlesPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup), height: 1, depth: 1)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(fixedGridAssignParticlesPipeline)
            encoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            encoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 1)
            encoder.setBuffer(fixedGridCellCountsBuffer, offset: 0, index: 2)
            encoder.setBytes(&assignParams, length: MemoryLayout<FixedGridAssignParticlesParams>.stride, index: 3)
            encoder.dispatchThreads(particleThreads, threadsPerThreadgroup: particleThreadgroup)
            encoder.endEncoding()
        }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(fixedGridPrepareGroupRangesPipeline)
            encoder.setBuffer(fixedGridCellCountsBuffer, offset: 0, index: 0)
            encoder.setBuffer(fixedGridCellScanBufferA, offset: 0, index: 1)
            encoder.setBytes(&cellParams, length: MemoryLayout<FixedGridCellCountParams>.stride, index: 2)
            encoder.dispatchThreads(cellThreads, threadsPerThreadgroup: cellThreadgroup)
            encoder.endEncoding()
        }

        var scanInputBuffer = fixedGridCellScanBufferA
        var scanOutputBuffer = fixedGridCellScanBufferB
        var stride = 1
        while stride < cellCount {
            var scanParams = FixedGridScanStepParams(cellCount: UInt32(cellCount), stride: UInt32(stride))
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(fixedGridScanGroupRangesPipeline)
                encoder.setBuffer(scanInputBuffer, offset: 0, index: 0)
                encoder.setBuffer(scanOutputBuffer, offset: 0, index: 1)
                encoder.setBytes(&scanParams, length: MemoryLayout<FixedGridScanStepParams>.stride, index: 2)
                encoder.dispatchThreads(cellThreads, threadsPerThreadgroup: cellThreadgroup)
                encoder.endEncoding()
            }
            swap(&scanInputBuffer, &scanOutputBuffer)
            stride <<= 1
        }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(fixedGridFinalizeGroupRangesPipeline)
            encoder.setBuffer(fixedGridCellCountsBuffer, offset: 0, index: 0)
            encoder.setBuffer(scanInputBuffer, offset: 0, index: 1)
            encoder.setBuffer(fixedGridCellOffsetsBuffer, offset: 0, index: 2)
            encoder.setBuffer(fixedGridCellWriteHeadsBuffer, offset: 0, index: 3)
            encoder.setBuffer(interactionRangesBuffer, offset: 0, index: 4)
            encoder.setBytes(&cellParams, length: MemoryLayout<FixedGridCellCountParams>.stride, index: 5)
            encoder.dispatchThreads(MTLSize(width: cellCount + 1, height: 1, depth: 1), threadsPerThreadgroup: cellThreadgroup)
            encoder.endEncoding()
        }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(fixedGridScatterParticleIndicesPipeline)
            encoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            encoder.setBuffer(interactionGroupIndicesBuffer, offset: 0, index: 1)
            encoder.setBuffer(fixedGridCellWriteHeadsBuffer, offset: 0, index: 2)
            encoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 3)
            encoder.setBuffer(interactionScratchParticlesBuffer ?? sourceParticleBuffer, offset: 0, index: 4)
            encoder.setBuffer(interactionScratchToCanonicalBuffer ?? interactionIndicesBuffer, offset: 0, index: 5)
            encoder.setBytes(&assignParams, length: MemoryLayout<FixedGridAssignParticlesParams>.stride, index: 6)
            encoder.dispatchThreads(particleThreads, threadsPerThreadgroup: particleThreadgroup)
            encoder.endEncoding()
        }
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
        let groups = interactionGroupIndicesBuffer.contents().bindMemory(to: UInt32.self, capacity: activeParticleCount)
        let groupIndex = Int(groups[particleIndex])
        let offsets = interactionRangeOffsetsBuffer.contents().bindMemory(to: UInt32.self, capacity: interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride)
        guard groupIndex + 1 < interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride else { return 0 }
        let rangeStart = Int(offsets[groupIndex])
        let rangeEnd = Int(offsets[groupIndex + 1])
        guard rangeEnd > rangeStart else { return 0 }
        let rangeTargets = interactionRangeTargetsBuffer.contents().bindMemory(to: UInt32.self, capacity: interactionRangeTargetsBuffer.length / MemoryLayout<UInt32>.stride)
        let ranges = interactionRangesBuffer.contents().bindMemory(to: InteractionRangeEntry.self, capacity: interactionRangesBuffer.length / MemoryLayout<InteractionRangeEntry>.stride)
        var count = 0
        for rangeIndex in rangeStart..<rangeEnd {
            count += Int(ranges[Int(rangeTargets[rangeIndex])].count)
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
        let groups = interactionGroupIndicesBuffer.contents().bindMemory(to: UInt32.self, capacity: activeParticleCount)
        let groupIndex = Int(groups[particleIndex])
        let offsets = interactionRangeOffsetsBuffer.contents().bindMemory(to: UInt32.self, capacity: interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride)
        guard groupIndex + 1 < interactionRangeOffsetsBuffer.length / MemoryLayout<UInt32>.stride else { return nil }
        let rangeStart = Int(offsets[groupIndex])
        let rangeEnd = Int(offsets[groupIndex + 1])
        guard rangeEnd > rangeStart else { return nil }
        let rangeTargets = interactionRangeTargetsBuffer.contents().bindMemory(to: UInt32.self, capacity: interactionRangeTargetsBuffer.length / MemoryLayout<UInt32>.stride)
        let ranges = interactionRangesBuffer.contents().bindMemory(to: InteractionRangeEntry.self, capacity: interactionRangesBuffer.length / MemoryLayout<InteractionRangeEntry>.stride)
        let indices = interactionIndicesBuffer.contents().bindMemory(to: UInt32.self, capacity: interactionIndicesBuffer.length / MemoryLayout<UInt32>.stride)
        for rangeIndex in rangeStart..<rangeEnd {
            let range = ranges[Int(rangeTargets[rangeIndex])]
            guard range.count > 0 else { continue }
            let targetIndex = Int(indices[Int(range.startIndex)])
            if activeFixedGridNeighborReadMode == .scratch, let interactionScratchToCanonicalBuffer {
                let reverse = interactionScratchToCanonicalBuffer.contents().bindMemory(to: UInt32.self, capacity: interactionScratchToCanonicalBuffer.length / MemoryLayout<UInt32>.stride)
                guard targetIndex < interactionScratchToCanonicalBuffer.length / MemoryLayout<UInt32>.stride else { return nil }
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

    private func makeCustomStandardPhysicsPipelinesIfNeeded(
        for descriptor: ModuleDescriptor
    ) throws -> (moduleID: String, accumulatePipeline: MTLComputePipelineState, applyPipeline: MTLComputePipelineState)? {
        guard descriptor.executionModel == .realtime,
              descriptor.pipelineStage == .processor,
              descriptor.kind == ModuleKind.physics.rawValue,
              !descriptor.isDefaultFallback,
              ModuleCatalog.knownModulesByName[descriptor.name] == nil else {
            return nil
        }

        guard let accumulateEntryPoint = descriptor.entryPoints.update.first else {
            throw SimulationRuntimeError.incompatibleModules(
                ActiveModuleSet(physics: descriptor, visual: activeModules.visual, optimization: activeModules.optimization),
                "Physics module \(descriptor.name) must declare an update entry point."
            )
        }
        guard let applyEntryPoint = descriptor.entryPoints.postUpdate.first else {
            throw SimulationRuntimeError.incompatibleModules(
                ActiveModuleSet(physics: descriptor, visual: activeModules.visual, optimization: activeModules.optimization),
                "Physics module \(descriptor.name) must declare a postUpdate entry point."
            )
        }
        guard let accumulateFunction = library.makeFunction(name: accumulateEntryPoint) else {
            throw SimulationRuntimeError.missingFunction(accumulateEntryPoint)
        }
        guard let applyFunction = library.makeFunction(name: applyEntryPoint) else {
            throw SimulationRuntimeError.missingFunction(applyEntryPoint)
        }

        do {
            return (
                descriptor.moduleID,
                try device.makeComputePipelineState(function: accumulateFunction),
                try device.makeComputePipelineState(function: applyFunction)
            )
        } catch {
            throw SimulationRuntimeError.computePipelineCreationFailed("\(accumulateEntryPoint) / \(applyEntryPoint)")
        }
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

        let previousPrimordialSoupLifecycleSidecarFront = primordialSoupLifecycleSidecarFrontBuffer
        primordialSoupLifecycleSidecarFrontBuffer = primordialSoupLifecycleSidecarBackBuffer
        primordialSoupLifecycleSidecarBackBuffer = previousPrimordialSoupLifecycleSidecarFront
    }

    private var isTypeMatrixPhysicsActive: Bool {
        activeModules.physics.name == TypeMatrixLocalPhysicsSettings.moduleName
    }

    private var isPrimordialSoupLifecyclePhysicsActive: Bool {
        activeModules.physics.name == PrimordialSoupLifecycleSettings.moduleName
    }

    private var isToyPlaybackActive: Bool {
        activeModules.optimization.name == "ToyPlaybackReader"
            && activeModules.physics.name == "ToyPlaybackProcessor"
            && activeModules.visual.name == "ToyPlaybackPresenter"
    }

    private var isMLPlaybackActive: Bool {
        activeModules.completeModuleFamilyID == ModuleCatalog.mlPlaybackFamilyID
    }

    private var isPlaybackRuntimeActive: Bool {
        isToyPlaybackActive || isMLPlaybackActive
    }

    private var isTemplatePhysicsActive: Bool {
        activeModules.physics.name == PhysicsModuleTemplateRuntime.moduleName
    }

    private var isCustomStandardPhysicsActive: Bool {
        customStandardPhysicsModuleID == activeModules.physics.moduleID
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

    private func uploadPrimordialSoupLifecycleBehaviorSpace(_ behaviorSpace: PrimordialSoupLifecycleBehaviorSpace) {
        let repaired = PrimordialSoupLifecycleSettings.repairedBehaviorSpace(behaviorSpace)
        let typeProfiles = repaired.typeProfiles.map {
            PrimordialSoupLifecycleTypeProfileGPU(
                maxSpeed: Float($0.maxSpeed),
                motility: Float($0.motility),
                innerRadius: Float(PrimordialSoupLifecycleSettings.worldUnits(fromCentimeters: $0.innerRadiusCentimeters)),
                middleRadius: Float(PrimordialSoupLifecycleSettings.worldUnits(fromCentimeters: $0.middleRadiusCentimeters)),
                outerRadius: Float(PrimordialSoupLifecycleSettings.worldUnits(fromCentimeters: $0.outerRadiusCentimeters)),
                energyDecayRate: Float($0.energyDecayRate),
                reproductionEnergyThreshold: Float($0.reproductionEnergyThreshold),
                reproductionEnergyCost: Float($0.reproductionEnergyCost),
                childEnergyFraction: Float($0.childEnergyFraction),
                reproductionCooldown: Float($0.reproductionCooldown),
                threatSensitivity: Float($0.threatSensitivity)
            )
        }
        let relationships = repaired.relationships.map {
            PrimordialSoupLifecycleRelationshipGPU(
                signedForce: Float($0.signedForce),
                energyCost: Float($0.energyCost),
                threatContribution: Float($0.threatContribution)
            )
        }
        primordialSoupLifecycleTypeProfileBuffer = makeBuffer(from: typeProfiles)
        primordialSoupLifecycleRelationshipBuffer = makeBuffer(from: relationships)
    }

    private func makeBuffer<T>(from values: [T]) -> MTLBuffer? {
        let storedCount = max(1, values.count)
        let length = max(1, MemoryLayout<T>.stride * storedCount)
        if values.isEmpty {
            return device.makeBuffer(length: length)
        }
        return values.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return device.makeBuffer(length: length)
            }
            return device.makeBuffer(bytes: baseAddress, length: length)
        }
    }
}
