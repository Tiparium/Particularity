import Metal
import MetalKit
import QuartzCore
import simd

enum RendererError: LocalizedError {
    case missingDevice
    case missingCommandQueue
    case missingFunction(String)
    case renderPipelineCreationFailed(String)
    case computePipelineCreationFailed(String)
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
        case .computePipelineCreationFailed(let name):
            return "Renderer failed to create the compute pipeline for '\(name)'."
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
    private let vertRibbonPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let profileHeaderParticlePipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let playbackMeshSmoothPipeline: MTLComputePipelineState
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
    private var meshIndexBuffer: MTLBuffer?
    private var meshIndexCount = 0
    private var meshGridSide = 0
    private var smoothedMeshParticleBuffer: MTLBuffer?
    private var smoothedMeshParticleBufferLength = 0

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
            let particleFragmentFunction = library.makeFunction(name: "particle_fs"),
            let profileHeaderVertexFunction = library.makeFunction(name: "profile_header_particle_vs"),
            let profileHeaderFragmentFunction = library.makeFunction(name: "profile_header_particle_fs"),
            let profileHeaderVertVertexFunction = library.makeFunction(name: "profile_header_vert_vs"),
            let profileHeaderVertFragmentFunction = library.makeFunction(name: "profile_header_vert_fs"),
            let meshVertexFunction = library.makeFunction(name: "ml_playback_surface_mesh_vs"),
            let meshFragmentFunction = library.makeFunction(name: "ml_playback_surface_mesh_fs"),
            let playbackMeshSmoothFunction = library.makeFunction(name: "ml_playback_surface_mesh_smooth")
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

        let vertRibbonDescriptor = MTLRenderPipelineDescriptor()
        vertRibbonDescriptor.vertexFunction = profileHeaderVertVertexFunction
        vertRibbonDescriptor.fragmentFunction = profileHeaderVertFragmentFunction
        vertRibbonDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        vertRibbonDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        vertRibbonDescriptor.inputPrimitiveTopology = .triangle
        vertRibbonDescriptor.colorAttachments[0].isBlendingEnabled = true
        vertRibbonDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        vertRibbonDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        vertRibbonDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        vertRibbonDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

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

        let profileHeaderDescriptor = particleDescriptor.copy() as! MTLRenderPipelineDescriptor
        profileHeaderDescriptor.vertexFunction = profileHeaderVertexFunction
        profileHeaderDescriptor.fragmentFunction = profileHeaderFragmentFunction

        let meshDescriptor = MTLRenderPipelineDescriptor()
        meshDescriptor.vertexFunction = meshVertexFunction
        meshDescriptor.fragmentFunction = meshFragmentFunction
        meshDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        meshDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        meshDescriptor.inputPrimitiveTopology = .triangle
        meshDescriptor.colorAttachments[0].isBlendingEnabled = true
        meshDescriptor.colorAttachments[0].rgbBlendOperation = .add
        meshDescriptor.colorAttachments[0].alphaBlendOperation = .add
        meshDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        meshDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        meshDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        meshDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

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
            vertRibbonPipeline = try device.makeRenderPipelineState(descriptor: vertRibbonDescriptor)
            particlePipeline = try device.makeRenderPipelineState(descriptor: particleDescriptor)
            profileHeaderParticlePipeline = try device.makeRenderPipelineState(descriptor: profileHeaderDescriptor)
            meshPipeline = try device.makeRenderPipelineState(descriptor: meshDescriptor)
        } catch {
            throw RendererError.renderPipelineCreationFailed(error.localizedDescription)
        }
        do {
            playbackMeshSmoothPipeline = try device.makeComputePipelineState(function: playbackMeshSmoothFunction)
        } catch {
            throw RendererError.computePipelineCreationFailed(error.localizedDescription)
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

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let projection = float4x4.perspective(fovY: 60.0 * .pi / 180.0, aspect: aspect, near: 0.1, far: 100.0)
        let projectionYScale = projection.columns.1.y
        let model = float4x4.identity()
        let mvp = projection * liveCameraState.viewMatrix() * model
        let mlSurfaceParticleCount: Int? = {
            guard simulationState.mlPlayback.isActive else { return nil }
            let surfaceCount = max(1, simulationState.mlPlayback.surfaceCount)
            let total = renderState.activeParticleCount
            guard total > 0, total % surfaceCount == 0 else { return nil }
            let perSurface = total / surfaceCount
            guard gridSide(for: perSurface) != nil else { return nil }
            return perSurface
        }()
        var meshParticleBufferForFrame: MTLBuffer?
        if renderState.activeParticleCount > 0,
           let particleBuffer = renderState.particleBuffer,
           simulationState.mlPlayback.isActive,
           simulationState.mlPlayback.surfaceMeshEnabled,
           let surfaceParticleCount = mlSurfaceParticleCount,
           let gridSide = gridSide(for: surfaceParticleCount),
           ensureMeshIndexBuffer(gridSide: gridSide) != nil,
           meshIndexCount > 0 {
            meshParticleBufferForFrame = smoothedMeshParticleBuffer(
                sourceParticleBuffer: particleBuffer,
                particleCount: renderState.activeParticleCount,
                gridSide: gridSide,
                smoothing: simulationState.mlPlayback.surfaceSmoothing,
                commandBuffer: commandBuffer
            )
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }

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

        if let presentationLineBuffer = renderState.presentationLineBuffer,
           renderState.presentationLineVertexCount > 0 {
            var presentationUniforms = LineUniforms(mvp: mvp, color: simulationState.profileHeader.vertColor)
            encoder.setRenderPipelineState(vertRibbonPipeline)
            encoder.setDepthStencilState(particleReadOnlyDepthState)
            encoder.setVertexBuffer(presentationLineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&presentationUniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: renderState.presentationLineVertexCount)
        }

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
            if simulationState.mlPlayback.isActive,
               simulationState.mlPlayback.surfaceMeshEnabled,
               let surfaceParticleCount = mlSurfaceParticleCount,
               let meshIndexBuffer = ensureMeshIndexBuffer(gridSide: gridSide(for: surfaceParticleCount) ?? 0),
               let meshParticleBuffer = meshParticleBufferForFrame,
               meshIndexCount > 0 {
                var surfaceUniforms = MLPlaybackSurfaceUniforms(
                    mvp: mvp,
                    spectrumOffset: simulationState.spectrumOffset,
                    amplitudeScale: simulationState.mlPlayback.amplitudeScale,
                    surfaceCount: UInt32(max(1, simulationState.mlPlayback.surfaceCount)),
                    visualRecipe: UInt32(simulationState.mlPlayback.visualRecipe.rawValueForShader),
                    frontLayerHorizontalOffset: simulationState.mlPlayback.frontLayer.horizontalOffset,
                    middleLayerHorizontalOffset: simulationState.mlPlayback.middleLayer.horizontalOffset,
                    finalLayerHorizontalOffset: simulationState.mlPlayback.finalLayer.horizontalOffset,
                    frontLayerOffset: simulationState.mlPlayback.frontLayer.heightOffset,
                    middleLayerOffset: simulationState.mlPlayback.middleLayer.heightOffset,
                    finalLayerOffset: simulationState.mlPlayback.finalLayer.heightOffset
                )
                encoder.setRenderPipelineState(meshPipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setVertexBuffer(meshParticleBuffer, offset: 0, index: 0)
                for surfaceIndex in 0..<max(1, simulationState.mlPlayback.surfaceCount) {
                    encoder.setVertexBytes(&surfaceUniforms, length: MemoryLayout<MLPlaybackSurfaceUniforms>.stride, index: 1)
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: meshIndexCount,
                        indexType: .uint32,
                        indexBuffer: meshIndexBuffer,
                        indexBufferOffset: 0,
                        instanceCount: 1,
                        baseVertex: surfaceIndex * surfaceParticleCount,
                        baseInstance: 0
                    )
                }
            } else {
                if simulationState.profileHeader.isActive {
                    var headerUniforms = ProfileHeaderParticleUniforms(mvp: mvp, nodeColor: simulationState.profileHeader.nodeColor, nodeSizeFloor: simulationState.profileHeader.nodeSizeFloor, nodeSizeCeiling: simulationState.profileHeader.nodeSizeCeiling, viewportHeight: Float(max(size.height, 1)), projectionYScale: projectionYScale)
                    encoder.setRenderPipelineState(profileHeaderParticlePipeline)
                    encoder.setDepthStencilState(particleReadOnlyDepthState)
                    encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&headerUniforms, length: MemoryLayout<ProfileHeaderParticleUniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: renderState.activeParticleCount)
                } else {
                encoder.setRenderPipelineState(particlePipeline)
                encoder.setDepthStencilState(simulationState.showOptimizationInfo ? particleReadOnlyDepthState : depthState)
                encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&particleUniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: renderState.activeParticleCount)
                }
            }
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

    private func gridSide(for particleCount: Int) -> Int? {
        guard particleCount > 3 else { return nil }
        let side = Int(Double(particleCount).squareRoot().rounded())
        guard side * side == particleCount, side >= 2 else { return nil }
        return side
    }

    private func ensureMeshIndexBuffer(gridSide: Int) -> MTLBuffer? {
        if meshGridSide == gridSide, let existing = meshIndexBuffer {
            return existing
        }

        let quadCount = (gridSide - 1) * (gridSide - 1)
        guard quadCount > 0 else { return nil }
        var indices: [UInt32] = []
        indices.reserveCapacity(quadCount * 6)

        for y in 0..<(gridSide - 1) {
            for x in 0..<(gridSide - 1) {
                let a = UInt32(y * gridSide + x)
                let b = UInt32(y * gridSide + (x + 1))
                let c = UInt32((y + 1) * gridSide + x)
                let d = UInt32((y + 1) * gridSide + (x + 1))
                indices.append(a)
                indices.append(c)
                indices.append(b)
                indices.append(b)
                indices.append(c)
                indices.append(d)
            }
        }

        guard let buffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride
        ) else {
            return nil
        }
        meshIndexBuffer = buffer
        meshIndexCount = indices.count
        meshGridSide = gridSide
        return buffer
    }

    private func smoothedMeshParticleBuffer(
        sourceParticleBuffer: MTLBuffer,
        particleCount: Int,
        gridSide: Int,
        smoothing: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLBuffer {
        let clampedSmoothing = min(max(smoothing, 0), 1)
        guard clampedSmoothing > 0.0001 else {
            return sourceParticleBuffer
        }

        let bufferLength = particleCount * MemoryLayout<ParticleState>.stride
        if smoothedMeshParticleBuffer == nil || smoothedMeshParticleBufferLength != bufferLength {
            smoothedMeshParticleBuffer = device.makeBuffer(length: bufferLength)
            smoothedMeshParticleBufferLength = bufferLength
        }
        guard let smoothedMeshParticleBuffer else {
            return sourceParticleBuffer
        }

        var params = PlaybackMeshSmoothParams(
            particleCount: UInt32(particleCount),
            gridSide: UInt32(gridSide),
            smoothing: clampedSmoothing
        )
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return sourceParticleBuffer
        }
        computeEncoder.setComputePipelineState(playbackMeshSmoothPipeline)
        computeEncoder.setBuffer(sourceParticleBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(smoothedMeshParticleBuffer, offset: 0, index: 1)
        computeEncoder.setBytes(&params, length: MemoryLayout<PlaybackMeshSmoothParams>.stride, index: 2)
        let width = playbackMeshSmoothPipeline.threadExecutionWidth
        let threadsPerThreadgroup = MTLSize(width: width, height: 1, depth: 1)
        let threadgroups = MTLSize(
            width: (particleCount + width - 1) / width,
            height: 1,
            depth: 1
        )
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()
        return smoothedMeshParticleBuffer
    }

    private func axisIntent(positive: String, negative: String) -> Float {
        var value: Float = 0
        if activeKeys.contains(positive) { value += 1 }
        if activeKeys.contains(negative) { value -= 1 }
        return value
    }

}
