import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import Testing
@testable import Particularity

@Suite("Media export")
struct MediaExportTests {
    @Test("fixed-step frame plan excludes the duplicate loop endpoint")
    func framePlanExcludesLoopEndpoint() {
        let plan = MediaExportFramePlan(
            durationSeconds: 2,
            framesPerSecond: 30,
            updatesPerSecond: 60
        )

        #expect(plan.frameCount == 60)
        #expect(plan.presentationTime(for: 0) == 0)
        #expect(plan.presentationTime(for: 59) < 2)
        #expect(plan.playbackTime(for: 1) == 1.0 / 30.0)
    }

    @Test("fixed-step frame plan quantizes playback to update boundaries")
    func framePlanQuantizesPlaybackTime() {
        let plan = MediaExportFramePlan(
            durationSeconds: 1,
            framesPerSecond: 24,
            updatesPerSecond: 60
        )

        #expect(plan.playbackTime(for: 1) == 2.0 / 60.0)
    }

    @Test("fixed-step frame plan distributes non-integer update ratios")
    func framePlanDistributesUpdateRatios() {
        let plan = MediaExportFramePlan(
            durationSeconds: 1,
            framesPerSecond: 24,
            updatesPerSecond: 60
        )

        #expect((0...4).map(plan.targetUpdateCount) == [0, 2, 5, 7, 10])
    }

    @Test("GIF encoder writes all requested frames")
    func gifEncoderWritesFrames() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-export-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: 2,
            framesPerSecond: 30,
            loopsForever: true
        )
        encoder.add(try solidImage(red: 255, green: 0, blue: 0))
        encoder.add(try solidImage(red: 0, green: 0, blue: 255))
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 2)
    }

    @Test("GIF encoder finalizes an open-ended recording")
    func gifEncoderFinalizesOpenEndedRecording() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-recording-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: 0,
            framesPerSecond: 30,
            loopsForever: true
        )
        encoder.add(try solidImage(red: 255, green: 0, blue: 0))
        encoder.add(try solidImage(red: 0, green: 0, blue: 255))
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test("GIF encoder preserves average timing for fractional centisecond rates")
    func gifEncoderDistributesFrameDelays() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-timing-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: 3,
            framesPerSecond: 30,
            loopsForever: true
        )
        encoder.add(try solidImage(red: 255, green: 0, blue: 0))
        encoder.add(try solidImage(red: 0, green: 255, blue: 0))
        encoder.add(try solidImage(red: 0, green: 0, blue: 255))
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let totalDelay = (0..<3).reduce(0.0) { total, index in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                  let delay = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double else {
                return total
            }
            return total + delay
        }
        #expect(abs(totalDelay - 0.1) < 0.000_1)
    }

    @Test("still-image encoders write PNG and JPEG files")
    func stillImageEncodersWriteSupportedFormats() throws {
        let image = try solidImage(red: 32, green: 96, blue: 192)

        for format in [MediaExportFormat.png, .jpeg] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "particularity-export-\(UUID().uuidString).\(format.fileExtension)"
            )
            defer { try? FileManager.default.removeItem(at: url) }

            try StillImageMediaEncoder.write(
                image,
                to: url,
                format: format,
                jpegQuality: 0.75
            )

            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetCount(source) == 1)
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 2)
            #expect(CGImageSourceGetType(source) as String? == format.contentType.identifier)
        }
    }

    @Test("Toy Playback renders through the offscreen GIF path")
    @MainActor
    func toyPlaybackRendersToGIF() async throws {
        let session = try await SimulationSession.create()
        let modules = ActiveModuleSet(
            physics: try #require(ModuleCatalog.knownModulesByName["ToyPlaybackProcessor"]),
            visual: try #require(ModuleCatalog.knownModulesByName["ToyPlaybackPresenter"]),
            optimization: try #require(ModuleCatalog.knownModulesByName["ToyPlaybackReader"])
        )
        try session.updateActiveModules(modules)

        let viewportStore = MainWindowViewportStateStore()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), device: session.device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        let renderer = try Renderer(
            mtkView: view,
            session: session,
            viewportStateStore: viewportStore
        )
        let image = try renderer.captureImage(
            size: CGSize(width: 320, height: 180),
            cameraState: viewportStore.viewportState.camera,
            showSimulationBounds: false,
            playbackTime: 1
        )

        #expect(image.width == 320)
        #expect(image.height == 180)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-toy-playback-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try GIFMediaEncoder(url: url, frameCount: 1, framesPerSecond: 30, loopsForever: true)
        encoder.add(image)
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 320)
    }

    @Test("realtime fixed step publishes one completed update")
    @MainActor
    func realtimeFixedStepPublishesCompletedUpdate() async throws {
        let session = try await SimulationSession.create()
        try session.updateActiveModules(
            ActiveModuleSet(
                physics: ModuleCatalog.defaultPhysics,
                visual: ModuleCatalog.defaultVisual,
                optimization: ModuleCatalog.defaultOptimization
            )
        )
        var state = session.simulationState
        state.transportState = .running
        state.particleCount = 32
        state.timeScale = 1
        state.movementDirection = SIMD3<Float>(1, 0, 0)
        session.updateSimulationState(state)

        await session.beginFixedStepCapture()
        let prepared = await session.prepareFixedStepFrame()
        #expect(prepared)
        let before = firstParticle(in: session)

        let advanced = await session.advanceFixedStep()
        #expect(advanced)
        let after = firstParticle(in: session)
        session.finishFixedStepCapture()

        #expect(before != nil)
        #expect(after != nil)
        #expect((after?.position.x ?? 0) > (before?.position.x ?? 0))
    }

    private func solidImage(red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let pixels: [UInt8] = [
            red, green, blue, 255, red, green, blue, 255,
            red, green, blue, 255, red, green, blue, 255,
        ]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    @MainActor
    private func firstParticle(in session: SimulationSession) -> ParticleState? {
        let renderState = session.renderState
        guard renderState.activeParticleCount > 0, let buffer = renderState.particleBuffer else { return nil }
        return buffer.contents().bindMemory(to: ParticleState.self, capacity: 1).pointee
    }
}
