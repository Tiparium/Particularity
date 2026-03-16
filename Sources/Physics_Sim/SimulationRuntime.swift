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

private struct SimulationPhysicsParams {
    var movementDirection: SIMD4<Float>
    var particleCount: UInt32
    var deltaTime: Float
    var padding: SIMD2<UInt32> = .zero
}

private struct SimulationOptimizationParams {
    var startPair: UInt64
    var pairCount: UInt64
    var particleCount: UInt32
    var threadCount: UInt32
}

private struct SimulationDebugLineParams {
    var particleCount: UInt32
    var segmentCount: UInt32
}

struct SimulationDebugLineSegment {
    var firstTargetIndex: UInt32
    var interactionCount: UInt32
    var firstVertexIndex: UInt32
    var padding: UInt32 = 0
}

private struct SimulationOptimizationScratch {
    var checksum: UInt32 = 0
}

private struct SimulationLineVertex {
    var position: SIMD3<Float>
}

struct SimulationDebugRenderSegment {
    var vertexStart: Int
    var vertexCount: Int
    var startedAt: TimeInterval
}

private struct OptimizationDispatchPlan {
    var startWorkItem: UInt64
    var workItemCount: UInt64
    var threadCount: UInt32
}

final class SimulationRuntime: @unchecked Sendable {
    struct RenderState {
        let particlePositionBuffer: MTLBuffer?
        let particleColorBuffer: MTLBuffer?
        let activeParticleCount: Int
        let particleCapacity: Int
        let debugLineBuffer: MTLBuffer?
        let debugRenderSegments: [SimulationDebugRenderSegment]
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let optimizationPipeline: MTLComputePipelineState
    private let physicsPipeline: MTLComputePipelineState
    private let debugLinePipeline: MTLComputePipelineState
    private var metricsSink: @MainActor (SimulationPerformanceMetrics) -> Void
    private let simulationQueue = DispatchQueue(label: "physics-sim.runtime.queue", qos: .userInitiated)
    private let snapshotLock = NSLock()

    private var simulationTimer: DispatchSourceTimer?
    private var simulationWorkInFlight = false
    private var tickingSuspended = false
    private var idleCallbacks: [@Sendable () -> Void] = []

    private var particlePositionBuffer: MTLBuffer?
    private var particleColorBuffer: MTLBuffer?
    private var debugLineBuffer: MTLBuffer?
    private var debugLineSegmentBuffer: MTLBuffer?
    private var optimizationScratchBuffer: MTLBuffer?
    private var activeParticleCount = 0
    private var particleCapacity = 0
    private var debugHistory = SimulationDebugHistory(historyCapacity: 8, visibilityDuration: 0.11)
    private var currentBatchProgress: UInt64 = 0
    private var needsParticleRebuild = true
    private var metricsEnabled = true

    private var currentSimulationState = SimulationViewportState(
        transportState: .stopped,
        particleCount: 20_000,
        randomDistribution: true,
        particleTypes: 6,
        movementDirection: SIMD3<Float>(0.82, 0.18, 0.12),
        timeScale: 1.0,
        sphereSize: 0.025,
        spectrumOffset: 0.0,
        showOptimizationInfo: false,
        optimizationBlockingMode: .fullBlocking
    )
    private var activeModules = ActiveModuleSet(
        physics: ModuleCatalog.defaultPhysics,
        visual: ModuleCatalog.defaultVisual,
        optimization: ModuleCatalog.defaultOptimization
    )

    private var renderStateSnapshot = RenderState(
        particlePositionBuffer: nil,
        particleColorBuffer: nil,
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
        movementDirection: SIMD3<Float>(0.82, 0.18, 0.12),
        timeScale: 1.0,
        sphereSize: 0.025,
        spectrumOffset: 0.0,
        showOptimizationInfo: false,
        optimizationBlockingMode: .fullBlocking
    )

    private var metricsAccumulator = SimulationMetricsAccumulator(sampleWindowSeconds: 3.0, publishInterval: 0.25)
    private let fixedBlockingTimeStep: Float = 1.0 / 60.0
    private let simulationTickInterval: TimeInterval = 1.0 / 60.0
    private let physicsThreadsPerGroup = 256
    private let optimizationPreferredThreadsPerGroup = 256
    private let optimizationTargetThreadgroupsPerChunk = 256
    private let optimizationTargetPairsPerThread = 64
    private let debugHistorySegmentCapacity = 8
    private let simulationQueueKey = DispatchSpecificKey<Void>()

    init(
        device: MTLDevice,
        library: MTLLibrary,
        metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void = { _ in }
    ) throws {
        guard let optimizationFunction = library.makeFunction(name: "optimization_chunk") else {
            throw SimulationRuntimeError.missingFunction("optimization_chunk")
        }
        guard let physicsFunction = library.makeFunction(name: "physics_step") else {
            throw SimulationRuntimeError.missingFunction("physics_step")
        }
        guard let debugLineFunction = library.makeFunction(name: "build_debug_lines") else {
            throw SimulationRuntimeError.missingFunction("build_debug_lines")
        }

        do {
            self.optimizationPipeline = try device.makeComputePipelineState(function: optimizationFunction)
            self.physicsPipeline = try device.makeComputePipelineState(function: physicsFunction)
            self.debugLinePipeline = try device.makeComputePipelineState(function: debugLineFunction)
        } catch {
            let failingName: String
            if (error as NSError).localizedDescription.contains("optimization_chunk") {
                failingName = "optimization_chunk"
            } else if (error as NSError).localizedDescription.contains("physics_step") {
                failingName = "physics_step"
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
        self.optimizationScratchBuffer = device.makeBuffer(length: MemoryLayout<SimulationOptimizationScratch>.stride)
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

    func setMetricsSink(_ sink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void) {
        simulationQueue.async {
            self.metricsSink = sink
        }
    }

    func updateActiveModules(_ nextModules: ActiveModuleSet) throws {
        try simulationQueue.sync {
            if let reason = ModuleCompatibility.incompatibilityReason(for: nextModules, state: currentSimulationState) {
                throw SimulationRuntimeError.incompatibleModules(nextModules, reason)
            }
            activeModules = nextModules
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

        let previous = self.currentSimulationState
        self.currentSimulationState = nextState
        let shouldRebuildParticles =
            previous.particleCount != nextState.particleCount
            || previous.randomDistribution != nextState.randomDistribution
            || previous.particleTypes != nextState.particleTypes
            || previous.spectrumOffset != nextState.spectrumOffset

        if nextState.transportState == .stopped {
            self.simulationWorkInFlight = false
            self.tickingSuspended = false
            self.idleCallbacks.removeAll(keepingCapacity: false)
            self.currentBatchProgress = 0
            self.debugHistory.reset()
            if shouldRebuildParticles || self.particlePositionBuffer == nil || self.particleColorBuffer == nil {
                self.needsParticleRebuild = true
                self.ensureParticleStateBuffer()
            }
            self.metricsAccumulator.reset()
        } else {
            if shouldRebuildParticles {
                self.needsParticleRebuild = true
            }

            if previous.optimizationBlockingMode != nextState.optimizationBlockingMode {
                self.currentBatchProgress = 0
                self.debugHistory.reset()
            }

            if previous.showOptimizationInfo && !nextState.showOptimizationInfo {
                self.debugHistory.reset()
            }

            if shouldRebuildParticles, !self.simulationWorkInFlight, nextState.transportState != .running {
                self.ensureParticleStateBuffer()
            }
        }

        self.publishSnapshots()
        self.reconfigureSimulationLoop()
        let stateSummary = InteractionSnapshotFormat.viewport(nextState)
        let renderSummary = InteractionSnapshotFormat.renderState(
            RenderState(
                particlePositionBuffer: particlePositionBuffer,
                particleColorBuffer: particleColorBuffer,
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
        particlePositionBuffer = nil
        particleColorBuffer = nil
        debugLineBuffer = nil
        debugLineSegmentBuffer = nil
        activeParticleCount = 0
        particleCapacity = 0
        currentBatchProgress = 0
        debugHistory.reset()
        metricsAccumulator.reset()
        needsParticleRebuild = true
        publishSnapshots()
    }

    private func stepSimulation(at now: TimeInterval) {
        guard !simulationWorkInFlight else { return }
        ensureParticleStateBuffer()

        guard currentSimulationState.transportState == .running,
              let particlePositionBuffer,
              activeParticleCount > 0,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            debugHistory.reset()
            publishSnapshots()
            return
        }
        simulationWorkInFlight = true

        let batchWorkItemCount = optimizationBatchWorkItemCount()
        let shouldBuildDebugLines = currentSimulationState.showOptimizationInfo
        let shouldCollectMetrics = metricsEnabled
        let dispatchPlans = optimizationDispatchPlans(
            for: batchWorkItemCount,
            blockingMode: currentSimulationState.optimizationBlockingMode
        )

        guard !dispatchPlans.isEmpty else {
            debugHistory.reset()
            publishSnapshots()
            return
        }

        var totalLeaderInteractionCount = 0
        let threadsPerGroupWidth = optimizationThreadsPerGroupWidth()

        if let scratch = optimizationScratchBuffer {
            scratch.contents().storeBytes(of: SimulationOptimizationScratch(), as: SimulationOptimizationScratch.self)
        }

        if let optimizationEncoder = commandBuffer.makeComputeCommandEncoder() {
            optimizationEncoder.setComputePipelineState(optimizationPipeline)
            optimizationEncoder.setBuffer(particlePositionBuffer, offset: 0, index: 0)
            optimizationEncoder.setBuffer(optimizationScratchBuffer, offset: 0, index: 2)
            let threadsPerGroup = MTLSize(width: threadsPerGroupWidth, height: 1, depth: 1)

            for plan in dispatchPlans {
                var params = SimulationOptimizationParams(
                    startPair: plan.startWorkItem,
                    pairCount: plan.workItemCount,
                    particleCount: UInt32(activeParticleCount),
                    threadCount: plan.threadCount
                )
                optimizationEncoder.setBytes(&params, length: MemoryLayout<SimulationOptimizationParams>.stride, index: 1)
                let threadCount = MTLSize(width: Int(plan.threadCount), height: 1, depth: 1)
                optimizationEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)

                if shouldBuildDebugLines || shouldCollectMetrics {
                    let leaderSweep = leaderSweepInfo(
                        startWorkItem: plan.startWorkItem,
                        workItemCount: plan.workItemCount
                    )
                    if shouldCollectMetrics {
                        totalLeaderInteractionCount += leaderSweep.count
                    }
                    if shouldBuildDebugLines,
                       let firstTargetIndex = leaderSweep.firstTargetIndex,
                       leaderSweep.count > 0 {
                        cacheLeaderSweepSegment(
                            firstTargetIndex: firstTargetIndex,
                            interactionCount: leaderSweep.count,
                            now: now
                        )
                    }
                }
            }
            optimizationEncoder.endEncoding()
        }

        let batchCompletes = dispatchPlans.last?.batchCompletes(batchWorkItemCount: batchWorkItemCount) ?? false

        if shouldBuildDebugLines {
            pruneDebugHistory(now: now)
            rebuildDebugRenderSegments()

            if let currentDebugLineBuffer = debugLineBuffer,
               let debugLineSegmentBuffer,
               !debugHistory.renderSegments.isEmpty,
               let debugLineEncoder = commandBuffer.makeComputeCommandEncoder() {
                debugLineEncoder.setComputePipelineState(debugLinePipeline)
                debugLineEncoder.setBuffer(particlePositionBuffer, offset: 0, index: 0)
                debugLineEncoder.setBuffer(currentDebugLineBuffer, offset: 0, index: 1)
                var params = SimulationDebugLineParams(
                    particleCount: UInt32(activeParticleCount),
                    segmentCount: UInt32(debugHistory.renderSegments.count)
                )
                debugLineEncoder.setBytes(&params, length: MemoryLayout<SimulationDebugLineParams>.stride, index: 2)
                debugLineEncoder.setBuffer(debugLineSegmentBuffer, offset: 0, index: 3)
                let vertexCount = max(1, debugHistory.renderSegments.reduce(0) { $0 + $1.vertexCount })
                let threads = MTLSize(width: vertexCount, height: 1, depth: 1)
                let threadgroup = MTLSize(width: min(debugLinePipeline.maxTotalThreadsPerThreadgroup, 64), height: 1, depth: 1)
                debugLineEncoder.dispatchThreads(threads, threadsPerThreadgroup: threadgroup)
                debugLineEncoder.endEncoding()
            }
        } else {
            debugHistory.reset()
        }

        currentBatchProgress += dispatchPlans.reduce(0) { $0 + $1.workItemCount }
        if batchCompletes {
            currentBatchProgress = 0
        }

        if shouldCollectMetrics, totalLeaderInteractionCount > 0 {
            metricsAccumulator.recordLeaderInteractions(totalLeaderInteractionCount, at: now)
        }

        let shouldAdvancePhysics = switch currentSimulationState.optimizationBlockingMode {
        case .nonBlocking: true
        case .fullBlocking: batchCompletes
        }

        if shouldAdvancePhysics, let physicsEncoder = commandBuffer.makeComputeCommandEncoder() {
            physicsEncoder.setComputePipelineState(physicsPipeline)
            physicsEncoder.setBuffer(particlePositionBuffer, offset: 0, index: 0)
            let deltaTime: Float = currentSimulationState.optimizationBlockingMode == .fullBlocking
                ? fixedBlockingTimeStep * currentSimulationState.timeScale
                : Float(simulationTickInterval) * currentSimulationState.timeScale
            var params = SimulationPhysicsParams(
                movementDirection: SIMD4<Float>(
                    currentSimulationState.movementDirection.x,
                    currentSimulationState.movementDirection.y,
                    currentSimulationState.movementDirection.z,
                    0
                ),
                particleCount: UInt32(activeParticleCount),
                deltaTime: deltaTime
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<SimulationPhysicsParams>.stride, index: 1)
            let threadsPerGroup = MTLSize(width: min(physicsPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup), height: 1, depth: 1)
            let threadCount = MTLSize(width: activeParticleCount, height: 1, depth: 1)
            physicsEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
            physicsEncoder.endEncoding()
            if shouldCollectMetrics {
                metricsAccumulator.recordPhysicsStep(at: now)
            }
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let runtime = self else { return }
            runtime.simulationQueue.async {
                runtime.simulationWorkInFlight = false
                runtime.drainIdleCallbacks()
            }
        }
        commandBuffer.commit()
        publishSnapshots()
    }

    private func ensureParticleStateBuffer() {
        guard needsParticleRebuild || particlePositionBuffer == nil || particleColorBuffer == nil else { return }

        let spawnData = DefaultPhysicsModuleRuntime.rebuildParticles(from: currentSimulationState)
        let positions = spawnData.positions
        let colors = spawnData.colors

        let positionLength = max(1, MemoryLayout<SIMD4<Float>>.stride * positions.count)
        if let existing = particlePositionBuffer, existing.length >= positionLength {
            let pointer = existing.contents().bindMemory(to: SIMD4<Float>.self, capacity: positions.count)
            pointer.update(from: positions, count: positions.count)
            particlePositionBuffer = existing
        } else {
            particlePositionBuffer = device.makeBuffer(bytes: positions, length: positionLength)
        }

        let colorLength = max(1, MemoryLayout<SIMD4<Float>>.stride * colors.count)
        if let existing = particleColorBuffer, existing.length >= colorLength {
            let pointer = existing.contents().bindMemory(to: SIMD4<Float>.self, capacity: colors.count)
            pointer.update(from: colors, count: colors.count)
            particleColorBuffer = existing
        } else {
            particleColorBuffer = device.makeBuffer(bytes: colors, length: colorLength)
        }

        activeParticleCount = spawnData.activeCount
        let positionCapacity = (particlePositionBuffer?.length ?? 0) / MemoryLayout<SIMD4<Float>>.stride
        let colorCapacity = (particleColorBuffer?.length ?? 0) / MemoryLayout<SIMD4<Float>>.stride
        particleCapacity = max(positionCapacity, colorCapacity)
        currentBatchProgress = 0
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
            particlePositionBuffer: particlePositionBuffer,
            particleColorBuffer: particleColorBuffer,
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

    private func optimizationBatchWorkItemCount() -> UInt64 {
        UInt64(activeParticleCount) * UInt64(activeParticleCount)
    }

    private func optimizationDispatchPlans(
        for batchWorkItemCount: UInt64,
        blockingMode: OptimizationBlockingMode
    ) -> [OptimizationDispatchPlan] {
        guard batchWorkItemCount > 0, currentBatchProgress < batchWorkItemCount else { return [] }

        let chunkWorkItemCount = optimizationChunkWorkItemCount(for: batchWorkItemCount)
        let remainingWorkItemCount = batchWorkItemCount - currentBatchProgress
        let maxDispatchCount = switch blockingMode {
        case .fullBlocking:
            Int.max
        case .nonBlocking:
            1
        }

        var plans: [OptimizationDispatchPlan] = []
        plans.reserveCapacity(min(maxDispatchCount, 16))

        var nextStartWorkItem = currentBatchProgress
        var remaining = remainingWorkItemCount

        while remaining > 0 && plans.count < maxDispatchCount {
            let workItemCount = min(chunkWorkItemCount, remaining)
            plans.append(
                OptimizationDispatchPlan(
                    startWorkItem: nextStartWorkItem,
                    workItemCount: workItemCount,
                    threadCount: optimizationThreadCount(for: workItemCount)
                )
            )
            nextStartWorkItem += workItemCount
            remaining -= workItemCount
        }

        return plans
    }

    private func optimizationChunkWorkItemCount(for batchWorkItemCount: UInt64) -> UInt64 {
        guard batchWorkItemCount > 0 else { return 0 }
        let plannedThreadCount = UInt64(optimizationPlannedThreadCount())
        let plannedChunkWorkItemCount = plannedThreadCount * UInt64(optimizationTargetPairsPerThread)
        return min(batchWorkItemCount, plannedChunkWorkItemCount)
    }

    private func optimizationThreadCount(for workItemCount: UInt64) -> UInt32 {
        let plannedThreadCount = UInt64(optimizationPlannedThreadCount())
        return UInt32(min(max(UInt64(1), workItemCount), plannedThreadCount))
    }

    private func optimizationPlannedThreadCount() -> Int {
        optimizationThreadsPerGroupWidth() * optimizationTargetThreadgroupsPerChunk
    }

    private func optimizationThreadsPerGroupWidth() -> Int {
        let maxThreads = min(optimizationPipeline.maxTotalThreadsPerThreadgroup, optimizationPreferredThreadsPerGroup)
        let executionWidth = max(1, optimizationPipeline.threadExecutionWidth)
        let alignedThreads = (maxThreads / executionWidth) * executionWidth
        return max(executionWidth, alignedThreads)
    }

    private func leaderSweepInfo(startWorkItem: UInt64, workItemCount: UInt64) -> (firstTargetIndex: Int?, count: Int) {
        guard workItemCount > 0 else { return (nil, 0) }
        let stride = UInt64(activeParticleCount)
        let chunkEnd = startWorkItem + workItemCount
        let firstLeaderPair = ((startWorkItem + stride - 1) / stride) * stride
        guard firstLeaderPair < chunkEnd else { return (nil, 0) }
        let lastLeaderPair = ((chunkEnd - 1) / stride) * stride
        let count = Int(((lastLeaderPair - firstLeaderPair) / stride) + 1)
        return (Int(firstLeaderPair / stride), count)
    }

    private func cacheLeaderSweepSegment(firstTargetIndex: Int, interactionCount: Int, now: TimeInterval) {
        debugHistory.cacheSegment(firstTargetIndex: firstTargetIndex, interactionCount: interactionCount, startedAt: now)
    }

    private func pruneDebugHistory(now: TimeInterval) {
        debugHistory.prune(now: now)
    }

    private func rebuildDebugRenderSegments() {
        debugHistory.rebuildRenderSegments(into: debugLineSegmentBuffer)
    }
}

private extension OptimizationDispatchPlan {
    func batchCompletes(batchWorkItemCount: UInt64) -> Bool {
        startWorkItem + workItemCount >= batchWorkItemCount
    }
}
