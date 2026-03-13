import Metal
import MetalKit
import QuartzCore
import simd
import Darwin.Mach

private struct LineUniforms {
    var mvp: float4x4
    var color: SIMD4<Float>
}

private struct ParticleUniforms {
    var mvp: float4x4
    var pointSize: Float
    var showOptimizationInfo: UInt32
    var padding: SIMD2<UInt32> = .zero
}

private struct PhysicsParams {
    var movementDirection: SIMD4<Float>
    var particleCount: UInt32
    var deltaTime: Float
    var padding: SIMD2<UInt32> = .zero
}

private struct OptimizationParams {
    var startPair: UInt64
    var pairCount: UInt64
    var particleCount: UInt32
    var threadCount: UInt32
}

private struct DebugLineParams {
    var firstTargetIndex: UInt32
    var interactionCount: UInt32
    var particleCount: UInt32
    var active: UInt32
}

private struct OptimizationScratch {
    var checksum: UInt32 = 0
}

private struct LineVertex {
    var position: SIMD3<Float>
}

private final class CameraState {
    var yaw: Float = 0.75
    var pitch: Float = 0.45
    var radius: Float = 3.6
    let minRadius: Float = 0.12
    let maxRadius: Float = 20.0
    let pitchLimit: Float = 1.35

    func reset() {
        yaw = 0.75
        pitch = 0.45
        radius = 3.6
    }

    func orbit(yawDelta: Float, pitchDelta: Float) {
        yaw += yawDelta
        pitch = max(-pitchLimit, min(pitchLimit, pitch + pitchDelta))
    }

    func dolly(delta: Float) {
        let next = radius * expf(delta)
        radius = max(minRadius, min(maxRadius, next))
    }

    func viewMatrix() -> float4x4 {
        let cx = cosf(pitch) * sinf(yaw)
        let cy = sinf(pitch)
        let cz = cosf(pitch) * cosf(yaw)
        let eye = float3(cx, cy, cz) * radius
        return .lookAt(eye: eye, center: float3(0, 0, 0), up: float3(0, 1, 0))
    }
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let linePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let optimizationPipeline: MTLComputePipelineState
    private let physicsPipeline: MTLComputePipelineState
    private let debugLinePipeline: MTLComputePipelineState
    private let depthState: MTLDepthStencilState
    private let particleReadOnlyDepthState: MTLDepthStencilState
    private let camera = CameraState()
    private let metricsSink: @MainActor (SimulationPerformanceMetrics) -> Void
    private let cameraStateSink: @MainActor (ViewportCameraState) -> Void
    private let debugLineFadeInDuration: TimeInterval = 0.018
    private let debugLineFadeOutDuration: TimeInterval = 0.055

    private var lineVertexBuffer: MTLBuffer
    private var lineIndexBuffer: MTLBuffer
    private var lineIndexCount: Int
    private var particlePositionBuffer: MTLBuffer?
    private var particleColorBuffer: MTLBuffer?
    private var debugLineBuffer: MTLBuffer?
    private var previousDebugLineBuffer: MTLBuffer?
    private var optimizationScratchBuffer: MTLBuffer?
    private var particleCount = 0
    private var debugLineVertexCount = 0
    private var previousDebugLineVertexCount = 0
    private var currentDebugLineStartedAt: TimeInterval = 0
    private var previousDebugLineFadeStartedAt: TimeInterval = 0
    private var currentPairStart: UInt64 = 0
    private var needsParticleRebuild = true

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

    private var frameTimestamps: [TimeInterval] = []
    private var physicsStepSamples: [(time: TimeInterval, count: Int)] = []
    private var leaderInteractionSamples: [(time: TimeInterval, count: Int)] = []
    private var lastMetricsPublishTime: TimeInterval = 0
    private let metricsWindowSeconds: TimeInterval = 3.0
    private let metricsPublishInterval: TimeInterval = 0.25
    private let fixedBlockingTimeStep: Float = 1.0 / 60.0
    private let optimizationThreadCount = 65_536
    private let physicsThreadsPerGroup = 256

    private var activeKeys: Set<String> = []
    private let keyboardAngularSpeed: Float = 1.2

    init?(
        mtkView: MTKView,
        metricsSink: @escaping @MainActor (SimulationPerformanceMetrics) -> Void = { _ in },
        cameraStateSink: @escaping @MainActor (ViewportCameraState) -> Void = { _ in }
    ) {
        guard
            let device = mtkView.device,
            let queue = device.makeCommandQueue()
        else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.metricsSink = metricsSink
        self.cameraStateSink = cameraStateSink

        let librarySource = [
            DefaultVisualModuleRuntime.shaderSource,
            DefaultPhysicsModuleRuntime.computeShaderSource,
            DefaultOptimizationModuleRuntime.computeShaderSource,
        ].joined(separator: "\n\n")

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: librarySource, options: nil)
        } catch {
            return nil
        }

        guard
            let lineVertexFunction = library.makeFunction(name: "line_vs"),
            let lineFragmentFunction = library.makeFunction(name: "line_fs"),
            let particleVertexFunction = library.makeFunction(name: "particle_vs"),
            let particleFragmentFunction = library.makeFunction(name: "particle_fs"),
            let optimizationFunction = library.makeFunction(name: "optimization_chunk"),
            let physicsFunction = library.makeFunction(name: "physics_step"),
            let debugLineFunction = library.makeFunction(name: "build_debug_lines")
        else {
            return nil
        }

        let lineDescriptor = MTLRenderPipelineDescriptor()
        lineDescriptor.vertexFunction = lineVertexFunction
        lineDescriptor.fragmentFunction = lineFragmentFunction
        lineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        lineDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        lineDescriptor.inputPrimitiveTopology = .line
        lineDescriptor.colorAttachments[0].isBlendingEnabled = true
        lineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        lineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        lineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        lineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        lineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        lineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let lineVertexDescriptor = MTLVertexDescriptor()
        lineVertexDescriptor.attributes[0].format = .float3
        lineVertexDescriptor.attributes[0].offset = 0
        lineVertexDescriptor.attributes[0].bufferIndex = 0
        lineVertexDescriptor.layouts[0].stride = MemoryLayout<LineVertex>.stride
        lineDescriptor.vertexDescriptor = lineVertexDescriptor

        let particleDescriptor = MTLRenderPipelineDescriptor()
        particleDescriptor.vertexFunction = particleVertexFunction
        particleDescriptor.fragmentFunction = particleFragmentFunction
        particleDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        particleDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        particleDescriptor.inputPrimitiveTopology = .point
        particleDescriptor.colorAttachments[0].isBlendingEnabled = true
        particleDescriptor.colorAttachments[0].rgbBlendOperation = .add
        particleDescriptor.colorAttachments[0].alphaBlendOperation = .add
        particleDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        particleDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        particleDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        particleDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let particleVertexDescriptor = MTLVertexDescriptor()
        particleVertexDescriptor.attributes[0].format = .float4
        particleVertexDescriptor.attributes[0].offset = 0
        particleVertexDescriptor.attributes[0].bufferIndex = 0
        particleVertexDescriptor.attributes[1].format = .float4
        particleVertexDescriptor.attributes[1].offset = 0
        particleVertexDescriptor.attributes[1].bufferIndex = 1
        particleVertexDescriptor.layouts[0].stride = MemoryLayout<SIMD4<Float>>.stride
        particleVertexDescriptor.layouts[1].stride = MemoryLayout<SIMD4<Float>>.stride
        particleDescriptor.vertexDescriptor = particleVertexDescriptor

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true

        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }
        self.depthState = depthState

        let particleDepthDescriptor = MTLDepthStencilDescriptor()
        particleDepthDescriptor.depthCompareFunction = .less
        particleDepthDescriptor.isDepthWriteEnabled = false

        guard let particleReadOnlyDepthState = device.makeDepthStencilState(descriptor: particleDepthDescriptor) else {
            return nil
        }
        self.particleReadOnlyDepthState = particleReadOnlyDepthState

        do {
            linePipeline = try device.makeRenderPipelineState(descriptor: lineDescriptor)
            particlePipeline = try device.makeRenderPipelineState(descriptor: particleDescriptor)
            optimizationPipeline = try device.makeComputePipelineState(function: optimizationFunction)
            physicsPipeline = try device.makeComputePipelineState(function: physicsFunction)
            debugLinePipeline = try device.makeComputePipelineState(function: debugLineFunction)
        } catch {
            return nil
        }

        let lineVertices: [LineVertex] = [
            LineVertex(position: [-1, -1, -1]),
            LineVertex(position: [ 1, -1, -1]),
            LineVertex(position: [ 1,  1, -1]),
            LineVertex(position: [-1,  1, -1]),
            LineVertex(position: [-1, -1,  1]),
            LineVertex(position: [ 1, -1,  1]),
            LineVertex(position: [ 1,  1,  1]),
            LineVertex(position: [-1,  1,  1]),
        ]

        let lineIndices: [UInt16] = [
            0,1, 1,2, 2,3, 3,0,
            4,5, 5,6, 6,7, 7,4,
            0,4, 1,5, 2,6, 3,7,
        ]

        guard
            let vb = device.makeBuffer(bytes: lineVertices, length: MemoryLayout<LineVertex>.stride * lineVertices.count),
            let ib = device.makeBuffer(bytes: lineIndices, length: MemoryLayout<UInt16>.stride * lineIndices.count),
            let debugLineBuffer = device.makeBuffer(length: MemoryLayout<LineVertex>.stride * 2),
            let previousDebugLineBuffer = device.makeBuffer(length: MemoryLayout<LineVertex>.stride * 2),
            let scratchBuffer = device.makeBuffer(length: MemoryLayout<OptimizationScratch>.stride)
        else {
            return nil
        }

        lineVertexBuffer = vb
        lineIndexBuffer = ib
        lineIndexCount = lineIndices.count
        self.debugLineBuffer = debugLineBuffer
        self.previousDebugLineBuffer = previousDebugLineBuffer
        optimizationScratchBuffer = scratchBuffer
        super.init()
        publishCameraState()
    }

    func registerKeyDown(_ key: String) {
        activeKeys.insert(key.lowercased())
    }

    func registerKeyUp(_ key: String) {
        activeKeys.remove(key.lowercased())
    }

    func orbitByDrag(deltaX: Float, deltaY: Float) {
        camera.orbit(yawDelta: deltaX * 0.01, pitchDelta: deltaY * 0.01)
        publishCameraState()
    }

    func dollyByScroll(deltaY: Float) {
        camera.dolly(delta: deltaY * 0.0035)
        publishCameraState()
    }

    func dollyByMagnification(_ magnification: Float) {
        camera.dolly(delta: -magnification * 0.6)
        publishCameraState()
    }

    func resetCamera() {
        camera.reset()
        publishCameraState()
    }

    func updateSimulationState(_ nextState: SimulationViewportState) {
        let previous = currentSimulationState
        currentSimulationState = nextState

        if nextState.transportState == .stopped {
            particlePositionBuffer = nil
            particleColorBuffer = nil
            particleCount = 0
            currentPairStart = 0
            debugLineVertexCount = 0
            previousDebugLineVertexCount = 0
            needsParticleRebuild = true
            physicsStepSamples.removeAll(keepingCapacity: false)
            leaderInteractionSamples.removeAll(keepingCapacity: false)
            return
        }

        if previous.particleCount != nextState.particleCount
            || previous.randomDistribution != nextState.randomDistribution
            || previous.particleTypes != nextState.particleTypes
            || previous.spectrumOffset != nextState.spectrumOffset {
            needsParticleRebuild = true
        }

        if previous.optimizationBlockingMode != nextState.optimizationBlockingMode {
            currentPairStart = 0
            debugLineVertexCount = 0
            previousDebugLineVertexCount = 0
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = ProcessInfo.processInfo.systemUptime
        recordFrame(at: now)
        updateKeyboardOrbit(deltaTime: 1.0 / 60.0)

        guard
            let drawable = view.currentDrawable,
            let passDesc = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer()
        else {
            return
        }

        ensureParticleStateBuffer()

        if currentSimulationState.transportState == .running {
            encodeSimulationPasses(on: commandBuffer, now: now)
        } else {
            debugLineVertexCount = 0
            previousDebugLineVertexCount = 0
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let projection = float4x4.perspective(fovY: 60.0 * .pi / 180.0, aspect: aspect, near: 0.1, far: 100.0)
        let model = float4x4.identity()
        let mvp = projection * camera.viewMatrix() * model

        var lineUniforms = LineUniforms(mvp: mvp, color: SIMD4<Float>(0.78, 0.78, 0.80, 1.0))
        encoder.setRenderPipelineState(linePipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(lineVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&lineUniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(
            type: .line,
            indexCount: lineIndexCount,
            indexType: .uint16,
            indexBuffer: lineIndexBuffer,
            indexBufferOffset: 0
        )

        if particleCount > 0, let particlePositionBuffer, let particleColorBuffer {
            var particleUniforms = ParticleUniforms(
                mvp: mvp,
                pointSize: DefaultOptimizationModuleRuntime.pointSize(for: currentSimulationState),
                showOptimizationInfo: currentSimulationState.showOptimizationInfo ? 1 : 0
            )
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setDepthStencilState(currentSimulationState.showOptimizationInfo ? particleReadOnlyDepthState : depthState)
            encoder.setVertexBuffer(particlePositionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(particleColorBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&particleUniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        }

        let previousDebugAlpha = previousDebugLineVertexCount > 0 ? debugLineFadeOutAlpha(at: now) : 0
        let currentDebugAlpha = debugLineVertexCount > 0 ? debugLineFadeInAlpha(at: now) : 0

        if previousDebugAlpha > 0, previousDebugLineVertexCount > 0, let previousDebugLineBuffer {
            var previousDebugLineUniforms = LineUniforms(
                mvp: mvp,
                color: SIMD4<Float>(1.0, 0.94, 0.38, Float(previousDebugAlpha))
            )
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(previousDebugLineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&previousDebugLineUniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: previousDebugLineVertexCount)
        }

        if currentDebugAlpha > 0, debugLineVertexCount > 0, let debugLineBuffer {
            var debugLineUniforms = LineUniforms(
                mvp: mvp,
                color: SIMD4<Float>(1.0, 0.94, 0.38, Float(currentDebugAlpha))
            )
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(debugLineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&debugLineUniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: debugLineVertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        publishMetricsIfNeeded(at: now)
    }

    private func ensureParticleStateBuffer() {
        guard currentSimulationState.transportState != .stopped else { return }
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

        particleCount = positions.count
        currentPairStart = 0
        debugLineVertexCount = 0
        needsParticleRebuild = false

        let maxDebugLineVertices = max(2, particleCount * 2)
        if debugLineBuffer == nil || debugLineBuffer?.length ?? 0 < MemoryLayout<LineVertex>.stride * maxDebugLineVertices {
            debugLineBuffer = device.makeBuffer(length: MemoryLayout<LineVertex>.stride * maxDebugLineVertices)
        }
        if previousDebugLineBuffer == nil || previousDebugLineBuffer?.length ?? 0 < MemoryLayout<LineVertex>.stride * maxDebugLineVertices {
            previousDebugLineBuffer = device.makeBuffer(length: MemoryLayout<LineVertex>.stride * maxDebugLineVertices)
        }
    }

    private func encodeSimulationPasses(on commandBuffer: MTLCommandBuffer, now: TimeInterval) {
        guard let particlePositionBuffer, particleCount > 0 else { return }

        let totalPairs = UInt64(particleCount) * UInt64(particleCount)
        let chunkPairs = DefaultOptimizationModuleRuntime.chunkPairCount(for: particleCount)
        let remainingPairs = totalPairs - currentPairStart
        let pairCountThisDispatch = min(chunkPairs, remainingPairs)
        let leaderSweep = leaderSweepInfoForCurrentChunk(pairCount: pairCountThisDispatch)
        let leaderInteractionCount = leaderSweep.count
        let cycleCompletes = currentPairStart + pairCountThisDispatch >= totalPairs

        if let scratch = optimizationScratchBuffer {
            scratch.contents().storeBytes(of: OptimizationScratch(), as: OptimizationScratch.self)
        }

        if let optimizationEncoder = commandBuffer.makeComputeCommandEncoder() {
            optimizationEncoder.setComputePipelineState(optimizationPipeline)
            optimizationEncoder.setBuffer(particlePositionBuffer, offset: 0, index: 0)
            var params = OptimizationParams(
                startPair: currentPairStart,
                pairCount: pairCountThisDispatch,
                particleCount: UInt32(particleCount),
                threadCount: UInt32(optimizationThreadCount)
            )
            optimizationEncoder.setBytes(&params, length: MemoryLayout<OptimizationParams>.stride, index: 1)
            optimizationEncoder.setBuffer(optimizationScratchBuffer, offset: 0, index: 2)
            let threadsPerGroup = MTLSize(width: min(optimizationPipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
            let threadCount = MTLSize(width: optimizationThreadCount, height: 1, depth: 1)
            optimizationEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
            optimizationEncoder.endEncoding()
        }

        if debugLineBuffer != nil {
            swap(&debugLineBuffer, &previousDebugLineBuffer)
            previousDebugLineVertexCount = debugLineVertexCount
            previousDebugLineFadeStartedAt = now

            if let currentDebugLineBuffer = debugLineBuffer,
               let debugLineEncoder = commandBuffer.makeComputeCommandEncoder() {
                debugLineEncoder.setComputePipelineState(debugLinePipeline)
                debugLineEncoder.setBuffer(particlePositionBuffer, offset: 0, index: 0)
                debugLineEncoder.setBuffer(currentDebugLineBuffer, offset: 0, index: 1)
                var params = DebugLineParams(
                    firstTargetIndex: UInt32(leaderSweep.firstTargetIndex ?? 0),
                    interactionCount: UInt32(leaderSweep.count),
                    particleCount: UInt32(particleCount),
                    active: (currentSimulationState.showOptimizationInfo && leaderSweep.count > 0) ? 1 : 0
                )
                debugLineEncoder.setBytes(&params, length: MemoryLayout<DebugLineParams>.stride, index: 2)
                let vertexCount = max(1, leaderSweep.count * 2)
                let threads = MTLSize(width: vertexCount, height: 1, depth: 1)
                let threadgroup = MTLSize(width: min(debugLinePipeline.maxTotalThreadsPerThreadgroup, 64), height: 1, depth: 1)
                debugLineEncoder.dispatchThreads(threads, threadsPerThreadgroup: threadgroup)
                debugLineEncoder.endEncoding()
            }
        }
        debugLineVertexCount = currentSimulationState.showOptimizationInfo ? leaderSweep.count * 2 : 0
        if debugLineVertexCount > 0 {
            currentDebugLineStartedAt = now
        }

        currentPairStart += pairCountThisDispatch
        if cycleCompletes {
            currentPairStart = 0
        }

        if leaderInteractionCount > 0 {
            recordSample(&leaderInteractionSamples, now: now, count: leaderInteractionCount)
        }

        let shouldAdvancePhysics = switch currentSimulationState.optimizationBlockingMode {
        case .nonBlocking: true
        case .fullBlocking: cycleCompletes
        }

        if shouldAdvancePhysics, let physicsEncoder = commandBuffer.makeComputeCommandEncoder() {
            physicsEncoder.setComputePipelineState(physicsPipeline)
            physicsEncoder.setBuffer(particlePositionBuffer, offset: 0, index: 0)
            let deltaTime: Float = currentSimulationState.optimizationBlockingMode == .fullBlocking
                ? fixedBlockingTimeStep * currentSimulationState.timeScale
                : (1.0 / 60.0) * currentSimulationState.timeScale
            var params = PhysicsParams(
                movementDirection: SIMD4<Float>(
                    currentSimulationState.movementDirection.x,
                    currentSimulationState.movementDirection.y,
                    currentSimulationState.movementDirection.z,
                    0
                ),
                particleCount: UInt32(particleCount),
                deltaTime: deltaTime
            )
            physicsEncoder.setBytes(&params, length: MemoryLayout<PhysicsParams>.stride, index: 1)
            let threadsPerGroup = MTLSize(width: min(physicsPipeline.maxTotalThreadsPerThreadgroup, physicsThreadsPerGroup), height: 1, depth: 1)
            let threadCount = MTLSize(width: particleCount, height: 1, depth: 1)
            physicsEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerGroup)
            physicsEncoder.endEncoding()
            recordSample(&physicsStepSamples, now: now, count: 1)
        }
    }

    private func leaderSweepInfoForCurrentChunk(pairCount: UInt64) -> (firstTargetIndex: Int?, count: Int) {
        guard pairCount > 0 else { return (nil, 0) }
        let stride = UInt64(particleCount)
        let chunkEnd = currentPairStart + pairCount
        let firstLeaderPair = ((currentPairStart + stride - 1) / stride) * stride
        guard firstLeaderPair < chunkEnd else { return (nil, 0) }
        let lastLeaderPair = ((chunkEnd - 1) / stride) * stride
        let count = Int(((lastLeaderPair - firstLeaderPair) / stride) + 1)
        return (Int(firstLeaderPair / stride), count)
    }

    private func updateKeyboardOrbit(deltaTime: Float) {
        var yawDelta: Float = 0
        var pitchDelta: Float = 0
        if activeKeys.contains("a") { yawDelta -= keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("d") { yawDelta += keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("w") { pitchDelta += keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("s") { pitchDelta -= keyboardAngularSpeed * deltaTime }
        if yawDelta != 0 || pitchDelta != 0 {
            camera.orbit(yawDelta: yawDelta, pitchDelta: pitchDelta)
            publishCameraState()
        }
    }

    private func publishCameraState() {
        cameraStateSink(
            ViewportCameraState(
                yaw: camera.yaw,
                pitch: camera.pitch
            )
        )
    }

    private func debugLineFadeInAlpha(at now: TimeInterval) -> Double {
        guard currentDebugLineStartedAt > 0 else { return 1 }
        let progress = min(max((now - currentDebugLineStartedAt) / debugLineFadeInDuration, 0), 1)
        return progress
    }

    private func debugLineFadeOutAlpha(at now: TimeInterval) -> Double {
        guard previousDebugLineFadeStartedAt > 0 else { return 0 }
        let progress = min(max((now - previousDebugLineFadeStartedAt) / debugLineFadeOutDuration, 0), 1)
        return 1 - progress
    }

    private func recordFrame(at now: TimeInterval) {
        frameTimestamps.append(now)
        let cutoff = now - metricsWindowSeconds
        frameTimestamps.removeAll { $0 < cutoff }
    }

    private func recordSample(_ samples: inout [(time: TimeInterval, count: Int)], now: TimeInterval, count: Int) {
        samples.append((time: now, count: count))
    }

    private func publishMetricsIfNeeded(at now: TimeInterval) {
        guard now - lastMetricsPublishTime >= metricsPublishInterval else { return }
        lastMetricsPublishTime = now

        pruneSamples(&physicsStepSamples, now: now)
        pruneSamples(&leaderInteractionSamples, now: now)

        let metrics = SimulationPerformanceMetrics(
            memoryUsedBytes: currentProcessResidentMemoryBytes(),
            averageFPS: ratePerSecond(for: frameTimestamps, fallbackWindow: metricsWindowSeconds),
            averageUPS: ratePerSecond(for: physicsStepSamples),
            leaderInteractionsPerSecond: ratePerSecond(for: leaderInteractionSamples),
            sampleWindowSeconds: metricsWindowSeconds
        )
        metricsSink(metrics)
    }

    private func pruneSamples(_ samples: inout [(time: TimeInterval, count: Int)], now: TimeInterval) {
        let cutoff = now - metricsWindowSeconds
        samples.removeAll { $0.time < cutoff }
    }

    private func ratePerSecond(for samples: [(time: TimeInterval, count: Int)]) -> Double {
        let totalCount = samples.reduce(0) { $0 + $1.count }
        guard let first = samples.first?.time, let last = samples.last?.time, last > first else {
            return samples.isEmpty ? 0 : Double(totalCount) / metricsWindowSeconds
        }
        return Double(totalCount) / max(last - first, 0.001)
    }

    private func ratePerSecond(for samples: [TimeInterval], fallbackWindow: TimeInterval) -> Double {
        guard let first = samples.first, let last = samples.last, last > first else {
            return samples.isEmpty ? 0 : Double(samples.count) / fallbackWindow
        }
        return Double(samples.count) / max(last - first, 0.001)
    }

    private func currentProcessResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
