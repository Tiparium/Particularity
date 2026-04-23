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
        fadeInDuration: 0.045,
        fadeOutDuration: 0.12
    )
    private var lastPublishedCameraState = ViewportCameraState()

    private var lineVertexBuffer: MTLBuffer
    private var lineIndexBuffer: MTLBuffer
    private var lineIndexCount: Int

    private var frameRateTracker = RendererFrameRateTracker(windowSeconds: 3.0)
    private var activeKeys: Set<String> = []
    private let orbitAngularSpeed: Float = 1.2
    private let orbitRadiusSpeed: Float = 1.6
    private let navigationTranslationSpeed: Float = 1.8
    private let slowRotationAngularSpeed: Float = 0.16
    private let slowRotationResumeDelay: TimeInterval = 3.0
    private let liveCameraState: CameraState
    private var lastManualCameraInteractionTime: TimeInterval = -.infinity
    private var lastSlowRotationEnabled = false

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
        self.liveCameraState = CameraState(viewportCameraState: viewportStateStore.viewportState.camera)

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
        registerManualCameraInteraction()
        let pitchDelta = -deltaY * 0.01
        if liveCameraState.authoritativeState.mode == .orbit {
            liveCameraState.updateOrbitMotion(yawDelta: deltaX * 0.01, pitchDelta: pitchDelta, radiusDelta: 0)
        } else {
            liveCameraState.rotateInPlace(yawDelta: deltaX * 0.01, pitchDelta: pitchDelta)
        }
        publishCameraState()
    }

    func dollyByScroll(deltaY: Float) {
        registerManualCameraInteraction()
        liveCameraState.adjustMovementSpeed(byScrollDelta: deltaY)
        viewportStateStore.setCameraMovementSpeed(liveCameraState.authoritativeState.movementSpeed)
        publishCameraState()
    }

    func dollyByMagnification(_ magnification: Float) {
        _ = magnification
    }

    func resetCamera() {
        registerManualCameraInteraction()
        liveCameraState.reset()
        commitCameraState()
        publishCameraState()
    }

    func commitCameraState() {
        viewportStateStore.checkpointCameraState(liveCameraState.authoritativeState)
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = ProcessInfo.processInfo.systemUptime
        frameRateTracker.recordFrame(at: now)
        syncCameraControlsFromViewportState(now: now)
        syncSlowRotationState(at: now)
        updateKeyboardCamera(deltaTime: 1.0 / 60.0)
        updateSlowRotation(deltaTime: 1.0 / 60.0, now: now)
        liveCameraState.updateTransition(now: now)
        publishCameraState()

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
        let mvp = projection * liveCameraState.viewMatrix() * model

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
           let particleBuffer = renderState.particleBuffer {
            var particleUniforms = ParticleUniforms(
                mvp: mvp,
                sphereSize: simulationState.sphereSize,
                viewportHeight: Float(max(size.height, 1)),
                projectionYScale: projectionYScale,
                spectrumOffset: simulationState.spectrumOffset,
                particleTypeCount: UInt32(max(1, simulationState.particleTypes)),
                showOptimizationInfo: simulationState.showOptimizationInfo ? 1 : 0
            )
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setDepthStencilState(simulationState.showOptimizationInfo ? particleReadOnlyDepthState : depthState)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&particleUniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
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

    private func updateKeyboardCamera(deltaTime: Float) {
        guard !liveCameraState.isTransitioning else { return }

        let forward = axisIntent(positive: "w", negative: "s")
        let right = axisIntent(positive: "d", negative: "a")
        let up = axisIntent(positive: "e", negative: "q")
        guard forward != 0 || right != 0 || up != 0 else { return }

        registerManualCameraInteraction()
        switch liveCameraState.authoritativeState.mode {
        case .orbit:
            let speed = liveCameraState.authoritativeState.movementSpeed
            liveCameraState.updateOrbitMotion(
                yawDelta: right * orbitAngularSpeed * speed * deltaTime,
                pitchDelta: up * orbitAngularSpeed * speed * deltaTime,
                radiusDelta: -forward * orbitRadiusSpeed * speed * deltaTime
            )
        case .navigation:
            let speed = navigationTranslationSpeed * liveCameraState.authoritativeState.movementSpeed
            let forwardScale: Float = forward >= 0 ? 1.0 : 0.75
            liveCameraState.updateNavigationTranslation(
                forward: forward * speed * forwardScale,
                right: right * speed * 0.75,
                up: up * speed * 0.5,
                deltaTime: deltaTime
            )
        }
        publishCameraState()
    }

    private func syncSlowRotationState(at now: TimeInterval) {
        let slowRotationEnabled = viewportStateStore.viewportState.slowRotationEnabled
        if slowRotationEnabled && !lastSlowRotationEnabled {
            lastManualCameraInteractionTime = now - slowRotationResumeDelay
        }
        lastSlowRotationEnabled = slowRotationEnabled
    }

    private func updateSlowRotation(deltaTime: Float, now: TimeInterval) {
        guard viewportStateStore.viewportState.slowRotationEnabled else { return }
        guard now - lastManualCameraInteractionTime >= slowRotationResumeDelay else { return }
        switch liveCameraState.authoritativeState.mode {
        case .orbit:
            liveCameraState.updateOrbitMotion(
                yawDelta: slowRotationAngularSpeed * deltaTime,
                pitchDelta: 0,
                radiusDelta: 0
            )
        case .navigation:
            liveCameraState.rotateInPlace(yawDelta: slowRotationAngularSpeed * deltaTime, pitchDelta: 0)
        }
        publishCameraState()
    }

    private func publishCameraState() {
        let cameraState = liveCameraState.renderedState
        guard cameraState.isMeaningfullyDifferent(from: lastPublishedCameraState) else { return }
        lastPublishedCameraState = cameraState
        cameraStateSink(cameraState)
    }

    private func registerManualCameraInteraction() {
        lastManualCameraInteractionTime = ProcessInfo.processInfo.systemUptime
    }

    private func syncCameraControlsFromViewportState(now: TimeInterval) {
        let desiredState = viewportStateStore.viewportState.camera
        let modeDidChange = desiredState.mode != liveCameraState.authoritativeState.mode
        liveCameraState.syncControls(from: desiredState, now: now)
        if modeDidChange {
            viewportStateStore.updateLiveCameraState(liveCameraState.authoritativeState)
            commitCameraState()
            publishCameraState()
        }
    }

    private func axisIntent(positive: String, negative: String) -> Float {
        var value: Float = 0
        if activeKeys.contains(positive) { value += 1 }
        if activeKeys.contains(negative) { value -= 1 }
        return value
    }

}
