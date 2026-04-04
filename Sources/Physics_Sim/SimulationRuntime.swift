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
    var interactionTraversalMode: UInt32
    var interactionRadius: Float
    var impulseScale: Float
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
    var innerRadius: Float
    var middleRadius: Float
    var outerRadius: Float
    var attractionMultiplier: Float
    var repulsionMultiplier: Float
    var interactionTraversalMode: UInt32
    var matrixSideLength: UInt32
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
}

private struct TemplatePhysicsAccumulateParams {
    var particleCount: UInt32
    var interactionTraversalMode: UInt32
    var interactionRadius: Float
    var impulseScale: Float
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
    var traversalMode: UInt32
    var padding0: UInt32 = 0
}

struct SimulationDebugLineSegment {
    var sourceParticleIndex: UInt32
    var interactionOffset: UInt32
    var interactionCount: UInt32
    var firstVertexIndex: UInt32
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
    private let commandQueue: MTLCommandQueue
    private let defaultPhysicsAccumulatePipeline: MTLComputePipelineState
    private let defaultPhysicsApplyPipeline: MTLComputePipelineState
    private let templatePhysicsAccumulatePipeline: MTLComputePipelineState
    private let templatePhysicsApplyPipeline: MTLComputePipelineState
    private let typeMatrixPhysicsAccumulatePipeline: MTLComputePipelineState
    private let typeMatrixPhysicsApplyPipeline: MTLComputePipelineState
    private let debugLinePipeline: MTLComputePipelineState
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
    private var interactionOffsetsBuffer: MTLBuffer?
    private var interactionIndicesBuffer: MTLBuffer?
    private var interactionTraversalMode: DefaultOptimizationModuleRuntime.InteractionTraversalMode = .canonicalRange
    private var typeMatrixInteractionBuffer: MTLBuffer?
    private var debugLineBuffer: MTLBuffer?
    private var debugLineSegmentBuffer: MTLBuffer?
    private var activeParticleCount = 0
    private var particleCapacity = 0
    private var debugHistory = SimulationDebugHistory(historyCapacity: 8, visibilityDuration: 0.11)
    private var leaderCommunicationLogEntries: [LeaderCommunicationLogEntry] = []
    private var needsParticleRebuild = true
    private var metricsEnabled = true
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
        showLeaderCommunicationLog: false,
        optimizationBlockingMode: .fullBlocking
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
        optimizationBlockingMode: .fullBlocking
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

        do {
            self.defaultPhysicsAccumulatePipeline = try device.makeComputePipelineState(function: physicsAccumulateFunction)
            self.defaultPhysicsApplyPipeline = try device.makeComputePipelineState(function: physicsApplyFunction)
            self.templatePhysicsAccumulatePipeline = try device.makeComputePipelineState(function: templatePhysicsAccumulateFunction)
            self.templatePhysicsApplyPipeline = try device.makeComputePipelineState(function: templatePhysicsApplyFunction)
            self.typeMatrixPhysicsAccumulatePipeline = try device.makeComputePipelineState(function: typeMatrixAccumulateFunction)
            self.typeMatrixPhysicsApplyPipeline = try device.makeComputePipelineState(function: typeMatrixApplyFunction)
            self.debugLinePipeline = try device.makeComputePipelineState(function: debugLineFunction)
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

    func setMetricsEnabled(_ enabled: Bool) {
        simulationQueue.async {
            self.metricsEnabled = enabled
            if !enabled {
                self.metricsAccumulator.reset()
            }
        }
    }

    func updateTypeMatrixLocalSettings(_ nextSettings: TypeMatrixLocalPhysicsSettings) {
        simulationQueue.async {
            self.typeMatrixLocalSettings = nextSettings
            guard self.currentSimulationState.transportState != .stopped,
                  self.isTypeMatrixPhysicsActive else {
                return
            }
            self.uploadTypeMatrixInteractionBuffer(from: nextSettings.matrixValues)
        }
    }

    func updateActiveModules(_ nextModules: ActiveModuleSet) throws {
        try simulationQueue.sync {
            if let reason = ModuleCompatibility.incompatibilityReason(for: nextModules, state: currentSimulationState) {
                throw SimulationRuntimeError.incompatibleModules(nextModules, reason)
            }
            activeModules = nextModules
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
        let shouldRebuildParticles =
            previous.particleCount != nextState.particleCount
            || previous.randomDistribution != nextState.randomDistribution
            || previous.particleTypes != nextState.particleTypes

        if nextState.transportState == .stopped {
            simulationWorkInFlight = false
            tickingSuspended = false
            idleCallbacks.removeAll(keepingCapacity: false)
            abandonEphemeralState()
        } else {
            if shouldRebuildParticles {
                needsParticleRebuild = true
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
            guard self.metricsEnabled else { return }
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
        interactionOffsetsBuffer = nil
        interactionIndicesBuffer = nil
        typeMatrixInteractionBuffer = nil
        debugLineBuffer = nil
        debugLineSegmentBuffer = nil
        activeParticleCount = 0
        particleCapacity = 0
        debugHistory.reset()
        clearLeaderCommunicationLog()
        metricsAccumulator.reset()
        needsParticleRebuild = true
        publishSnapshots()
    }

    private func stepSimulation(at now: TimeInterval) {
        guard !simulationWorkInFlight else { return }
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
        simulationWorkInFlight = true

        let interParticleCommunicationEnabled = currentSimulationState.allParticlesIntercommunicate
        let shouldBuildDebugLines = interParticleCommunicationEnabled && currentSimulationState.showOptimizationInfo
        let shouldRecordLeaderLog = interParticleCommunicationEnabled && currentSimulationState.showLeaderCommunicationLog
        let leaderInteractionOffset = 0
        let leaderInteractionCount = interParticleCommunicationEnabled ? activeParticleCount : 0

        if interParticleCommunicationEnabled,
           let interactionOffsetsBuffer,
           let interactionIndicesBuffer,
           let physicsEncoder = commandBuffer.makeComputeCommandEncoder() {
            encodePhysicsAccumulate(
                into: physicsEncoder,
                sourceParticleBuffer: particleFrontBuffer,
                destinationParticleBuffer: particleBackBuffer,
                interactionOffsetsBuffer: interactionOffsetsBuffer,
                interactionIndicesBuffer: interactionIndicesBuffer
            )
        } else {
            zeroParticleImpulseChannel()
        }

        if shouldBuildDebugLines {
            pruneDebugHistory(now: now)
            cacheLeaderSweepSegment(
                sourceParticleIndex: 0,
                interactionOffset: leaderInteractionOffset,
                interactionCount: leaderInteractionCount,
                now: now
            )
            rebuildDebugRenderSegments()

            if let interactionIndicesBuffer,
               let currentDebugLineBuffer = debugLineBuffer,
               let debugLineSegmentBuffer,
               !debugHistory.renderSegments.isEmpty,
               let debugLineEncoder = commandBuffer.makeComputeCommandEncoder() {
                debugLineEncoder.setComputePipelineState(debugLinePipeline)
                debugLineEncoder.setBuffer(particleFrontBuffer, offset: 0, index: 0)
                debugLineEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 1)
                debugLineEncoder.setBuffer(currentDebugLineBuffer, offset: 0, index: 2)
                var params = SimulationDebugLineParams(
                    segmentCount: UInt32(debugHistory.renderSegments.count),
                    particleCount: UInt32(activeParticleCount),
                    traversalMode: interactionTraversalMode.rawValue
                )
                debugLineEncoder.setBytes(&params, length: MemoryLayout<SimulationDebugLineParams>.stride, index: 3)
                debugLineEncoder.setBuffer(debugLineSegmentBuffer, offset: 0, index: 4)
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
                firstTargetIndex: 0,
                interactionCount: leaderInteractionCount,
                startWorkItem: UInt64(leaderInteractionOffset),
                workItemCount: UInt64(leaderInteractionCount)
            )
        } else if currentSimulationState.showLeaderCommunicationLog {
            publishLeaderCommunicationLog()
        }

        if metricsEnabled, leaderInteractionCount > 0 {
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

    private func encodePhysicsAccumulate(
        into physicsEncoder: MTLComputeCommandEncoder,
        sourceParticleBuffer: MTLBuffer,
        destinationParticleBuffer: MTLBuffer,
        interactionOffsetsBuffer: MTLBuffer,
        interactionIndicesBuffer: MTLBuffer
    ) {
        if isTypeMatrixPhysicsActive {
            guard let typeMatrixInteractionBuffer else {
                zeroParticleImpulseChannel()
                physicsEncoder.endEncoding()
                return
            }

            physicsEncoder.setComputePipelineState(typeMatrixPhysicsAccumulatePipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            physicsEncoder.setBuffer(interactionOffsetsBuffer, offset: 0, index: 2)
            physicsEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 3)
            physicsEncoder.setBuffer(typeMatrixInteractionBuffer, offset: 0, index: 4)
            var params = TypeMatrixPhysicsAccumulateParams(
                particleCount: UInt32(activeParticleCount),
                particleTypeCount: UInt32(max(1, currentSimulationState.particleTypes)),
                innerRadius: Float(typeMatrixLocalSettings.innerRadiusWorldUnits),
                middleRadius: Float(typeMatrixLocalSettings.middleRadiusWorldUnits),
                outerRadius: Float(typeMatrixLocalSettings.outerRadiusWorldUnits),
                attractionMultiplier: Float(typeMatrixLocalSettings.attractionMultiplier),
                repulsionMultiplier: Float(typeMatrixLocalSettings.repulsionMultiplier),
                interactionTraversalMode: interactionTraversalMode.rawValue,
                matrixSideLength: UInt32(TypeMatrixLocalPhysicsSettings.maxParticleTypes)
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TypeMatrixPhysicsAccumulateParams>.stride, index: 5)
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
            physicsEncoder.setBuffer(interactionOffsetsBuffer, offset: 0, index: 2)
            physicsEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 3)
            var params = TemplatePhysicsAccumulateParams(
                particleCount: UInt32(activeParticleCount),
                interactionTraversalMode: interactionTraversalMode.rawValue,
                interactionRadius: 0.18,
                impulseScale: 0.004
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TemplatePhysicsAccumulateParams>.stride, index: 4)
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
        physicsEncoder.setBuffer(interactionOffsetsBuffer, offset: 0, index: 2)
        physicsEncoder.setBuffer(interactionIndicesBuffer, offset: 0, index: 3)
        var params = SimulationPhysicsAccumulateParams(
            particleCount: UInt32(activeParticleCount),
            interactionTraversalMode: interactionTraversalMode.rawValue,
            interactionRadius: 0.42,
            impulseScale: 0.018 * currentSimulationState.timeScale
        )
        physicsEncoder.setBytes(&params, length: MemoryLayout<SimulationPhysicsAccumulateParams>.stride, index: 4)
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
            physicsEncoder.setComputePipelineState(typeMatrixPhysicsApplyPipeline)
            physicsEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
            physicsEncoder.setBuffer(destinationParticleBuffer, offset: 0, index: 1)
            var params = TypeMatrixPhysicsApplyParams(
                particleCount: UInt32(activeParticleCount),
                deltaTime: fixedTimeStep * currentSimulationState.timeScale,
                dampingEnabled: typeMatrixLocalSettings.dampingEnabled ? 1 : 0,
                momentumEnabled: typeMatrixLocalSettings.momentumEnabled ? 1 : 0,
                speedLimitEnabled: typeMatrixLocalSettings.speedLimitEnabled ? 1 : 0,
                dampingStrength: Float(typeMatrixLocalSettings.dampingStrength),
                momentumStrength: Float(typeMatrixLocalSettings.momentumStrength),
                speedLimit: Float(typeMatrixLocalSettings.speedLimit)
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<TypeMatrixPhysicsApplyParams>.stride, index: 2)
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
        if metricsEnabled {
            metricsAccumulator.recordPhysicsStep(at: now)
        }
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
            workItemCount: workItemCount,
            blockingMode: currentSimulationState.optimizationBlockingMode
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
            || interactionOffsetsBuffer == nil
            || interactionIndicesBuffer == nil else { return }

        let spawnData = DefaultPhysicsModuleRuntime.rebuildParticles(from: currentSimulationState)
        let particles = spawnData.particles
        let interactionPlan = DefaultOptimizationModuleRuntime.rebuildInteractionPlan(particleCount: spawnData.activeCount)
        interactionTraversalMode = interactionPlan.traversalMode

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

        let offsetsLength = max(1, MemoryLayout<UInt32>.stride * interactionPlan.offsets.count)
        if let existing = interactionOffsetsBuffer, existing.length >= offsetsLength {
            let pointer = existing.contents().bindMemory(to: UInt32.self, capacity: interactionPlan.offsets.count)
            pointer.update(from: interactionPlan.offsets, count: interactionPlan.offsets.count)
            interactionOffsetsBuffer = existing
        } else {
            interactionOffsetsBuffer = device.makeBuffer(bytes: interactionPlan.offsets, length: offsetsLength)
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
        } else {
            if interactionPlan.indices.isEmpty {
                var placeholderIndex: UInt32 = 0
                interactionIndicesBuffer = device.makeBuffer(bytes: &placeholderIndex, length: indicesLength)
            } else {
                interactionIndicesBuffer = device.makeBuffer(bytes: interactionPlan.indices, length: indicesLength)
            }
        }

        activeParticleCount = spawnData.activeCount
        particleCapacity = (particleFrontBuffer?.length ?? 0) / MemoryLayout<ParticleState>.stride
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
        interactionOffset: Int,
        interactionCount: Int,
        now: TimeInterval
    ) {
        guard interactionCount > 0 else { return }
        debugHistory.cacheSegment(
            sourceParticleIndex: sourceParticleIndex,
            interactionOffset: interactionOffset,
            interactionCount: interactionCount,
            startedAt: now
        )
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
    }

    private var isTypeMatrixPhysicsActive: Bool {
        activeModules.physics.name == TypeMatrixLocalPhysicsSettings.moduleName
    }

    private var isTemplatePhysicsActive: Bool {
        activeModules.physics.name == PhysicsModuleTemplateRuntime.moduleName
    }

    private func uploadTypeMatrixInteractionBuffer(from sourceMatrix: [Int]) {
        let matrix = sourceMatrix.map(Int32.init)
        let length = max(1, MemoryLayout<Int32>.stride * matrix.count)
        if let existing = typeMatrixInteractionBuffer, existing.length >= length {
            let pointer = existing.contents().bindMemory(to: Int32.self, capacity: matrix.count)
            pointer.update(from: matrix, count: matrix.count)
            typeMatrixInteractionBuffer = existing
        } else {
            typeMatrixInteractionBuffer = device.makeBuffer(bytes: matrix, length: length)
        }
    }
}
