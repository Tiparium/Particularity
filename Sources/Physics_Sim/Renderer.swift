import Metal
import MetalKit
import QuartzCore
import simd

enum RendererError: LocalizedError {
    case missingDevice
    case missingCommandQueue
    case missingFunction(String)
    case renderPipelineCreationFailed(String)
    case depthStateCreationFailed(String)
    case vertexBufferCreationFailed(String)
    case incompatibleModules(ActiveModuleSet, String)

    var errorDescription: String? {
        switch self {
        case .missingDevice:
            return "Renderer could not acquire a Metal device."
        case .missingCommandQueue:
            return "Renderer could not create a Metal command queue."
        case .missingFunction(let name):
            return "Renderer is missing the Metal function '\(name)'."
        case .renderPipelineCreationFailed(let name):
            return "Renderer failed to create the render pipeline for '\(name)'."
        case .depthStateCreationFailed(let label):
            return "Renderer failed to create the depth state '\(label)'."
        case .vertexBufferCreationFailed(let label):
            return "Renderer failed to create the vertex buffer '\(label)'."
        case .incompatibleModules(let modules, let reason):
            return "Incompatible active modules: physics=\(modules.physics.name), visual=\(modules.visual.name), optimization=\(modules.optimization.name). \(reason)"
        }
    }
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let session: SimulationSession
    private let viewportStateStore: MainWindowViewportStateStore
    private let linePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let particleReadOnlyDepthState: MTLDepthStencilState
    private let cameraStateSink: @MainActor (ViewportCameraState) -> Void
    private let debugLineFadeController = DebugLineFadeController(
        fadeInDuration: 0.018,
        fadeOutDuration: 0.055
    )
    private var lastPublishedCameraState = ViewportCameraState()

    private var lineVertexBuffer: MTLBuffer
    private var lineIndexBuffer: MTLBuffer
    private var lineIndexCount: Int

    private var frameRateTracker = RendererFrameRateTracker(windowSeconds: 3.0)
    private var activeKeys: Set<String> = []
    private let keyboardAngularSpeed: Float = 1.2

    init(
        mtkView: MTKView,
        session: SimulationSession,
        viewportStateStore: MainWindowViewportStateStore,
        cameraStateSink: @escaping @MainActor (ViewportCameraState) -> Void = { _ in }
    ) throws {
        guard let device = mtkView.device else {
            throw RendererError.missingDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.missingCommandQueue
        }
        self.device = device
        self.queue = queue
        self.viewportStateStore = viewportStateStore
        self.cameraStateSink = cameraStateSink

        let library = session.library

        guard
            let lineVertexFunction = library.makeFunction(name: "line_vs"),
            let lineFragmentFunction = library.makeFunction(name: "line_fs"),
            let particleVertexFunction = library.makeFunction(name: "particle_vs"),
            let particleFragmentFunction = library.makeFunction(name: "particle_fs")
        else {
            throw RendererError.missingFunction("render shader entry point")
        }
        self.session = session

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
            throw RendererError.depthStateCreationFailed("main-depth")
        }
        self.depthState = depthState

        let particleDepthDescriptor = MTLDepthStencilDescriptor()
        particleDepthDescriptor.depthCompareFunction = .less
        particleDepthDescriptor.isDepthWriteEnabled = false
        guard let particleReadOnlyDepthState = device.makeDepthStencilState(descriptor: particleDepthDescriptor) else {
            throw RendererError.depthStateCreationFailed("particle-readonly-depth")
        }
        self.particleReadOnlyDepthState = particleReadOnlyDepthState

        do {
            linePipeline = try device.makeRenderPipelineState(descriptor: lineDescriptor)
            particlePipeline = try device.makeRenderPipelineState(descriptor: particleDescriptor)
        } catch {
            throw RendererError.renderPipelineCreationFailed(error.localizedDescription)
        }

        let geometry = try TSPWireframeGeometry.make(device: device)
        lineVertexBuffer = geometry.vertexBuffer
        lineIndexBuffer = geometry.indexBuffer
        lineIndexCount = geometry.indexCount
        super.init()
        lastPublishedCameraState = viewportStateStore.viewportState.camera
        publishCameraState()
    }

    func registerKeyDown(_ key: String) {
        activeKeys.insert(key.lowercased())
    }

    func registerKeyUp(_ key: String) {
        activeKeys.remove(key.lowercased())
    }

    func orbitByDrag(deltaX: Float, deltaY: Float) {
        let camera = currentCameraState()
        camera.orbit(yawDelta: deltaX * 0.01, pitchDelta: deltaY * 0.01)
        persistCameraState(camera)
        publishCameraState()
    }

    func dollyByScroll(deltaY: Float) {
        let camera = currentCameraState()
        camera.dolly(delta: deltaY * 0.0035)
        persistCameraState(camera)
        publishCameraState()
    }

    func dollyByMagnification(_ magnification: Float) {
        let camera = currentCameraState()
        camera.dolly(delta: -magnification * 0.6)
        persistCameraState(camera)
        publishCameraState()
    }

    func resetCamera() {
        let camera = currentCameraState()
        camera.reset()
        persistCameraState(camera)
        publishCameraState()
    }

    func updateSimulationState(_ nextState: SimulationViewportState) {
        session.updateSimulationState(nextState)
    }

    func updateActiveModules(_ nextModules: ActiveModuleSet) throws {
        if let reason = ModuleCompatibility.incompatibilityReason(for: nextModules, state: session.simulationState) {
            throw RendererError.incompatibleModules(nextModules, reason)
        }
        try session.updateActiveModules(nextModules)
    }

    func setMetricsEnabled(_ enabled: Bool) {
        session.setMetricsEnabled(enabled)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = ProcessInfo.processInfo.systemUptime
        frameRateTracker.recordFrame(at: now)
        updateKeyboardOrbit(deltaTime: 1.0 / 60.0)

        guard
            let drawable = view.currentDrawable,
            let passDesc = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer()
        else {
            return
        }

        let renderState = session.renderState
        let simulationState = session.simulationState

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let projection = float4x4.perspective(fovY: 60.0 * .pi / 180.0, aspect: aspect, near: 0.1, far: 100.0)
        let projectionYScale = projection.columns.1.y
        let model = float4x4.identity()
        let mvp = projection * currentCameraState().viewMatrix() * model

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

        if renderState.activeParticleCount > 0,
           let particlePositionBuffer = renderState.particlePositionBuffer,
           let particleColorBuffer = renderState.particleColorBuffer {
            var particleUniforms = ParticleUniforms(
                mvp: mvp,
                sphereSize: simulationState.sphereSize,
                viewportHeight: Float(max(size.height, 1)),
                projectionYScale: projectionYScale,
                showOptimizationInfo: simulationState.showOptimizationInfo ? 1 : 0
            )
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setDepthStencilState(simulationState.showOptimizationInfo ? particleReadOnlyDepthState : depthState)
            encoder.setVertexBuffer(particlePositionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(particleColorBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&particleUniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: renderState.activeParticleCount)
        }

        if let debugLineBuffer = renderState.debugLineBuffer {
            for segment in renderState.debugRenderSegments {
                let alpha = debugLineFadeController.alpha(at: now, startedAt: segment.startedAt)
                guard alpha > 0, segment.vertexCount > 0 else { continue }

                var debugLineUniforms = LineUniforms(
                    mvp: mvp,
                    color: SIMD4<Float>(1.0, 0.94, 0.38, Float(alpha))
                )
                encoder.setRenderPipelineState(linePipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setVertexBuffer(debugLineBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&debugLineUniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: segment.vertexStart, vertexCount: segment.vertexCount)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        let currentFPS = frameRateTracker.averageFPS()
        session.publishFrameMetrics(averageFPS: currentFPS, at: now)
    }

    private func updateKeyboardOrbit(deltaTime: Float) {
        var yawDelta: Float = 0
        var pitchDelta: Float = 0
        if activeKeys.contains("a") { yawDelta -= keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("d") { yawDelta += keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("w") { pitchDelta += keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("s") { pitchDelta -= keyboardAngularSpeed * deltaTime }
        if yawDelta != 0 || pitchDelta != 0 {
            let camera = currentCameraState()
            camera.orbit(yawDelta: yawDelta, pitchDelta: pitchDelta)
            persistCameraState(camera)
            publishCameraState()
        }
    }

    private func publishCameraState() {
        let cameraState = viewportStateStore.viewportState.camera
        guard cameraState.isMeaningfullyDifferent(from: lastPublishedCameraState) else { return }
        lastPublishedCameraState = cameraState
        cameraStateSink(cameraState)
    }

    private func currentCameraState() -> CameraState {
        let camera = CameraState()
        camera.viewportCameraState = viewportStateStore.viewportState.camera
        return camera
    }

    private func persistCameraState(_ camera: CameraState) {
        viewportStateStore.updateCameraState(camera.viewportCameraState)
    }
}
