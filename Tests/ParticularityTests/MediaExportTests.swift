import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import Testing
@testable import Particularity

@Suite("Media export")
struct MediaExportTests {
    @Test("capture preview geometry matches the offscreen camera gate")
    func capturePreviewMatchesOffscreenProjection() {
        let viewportSize = CGSize(width: 1000, height: 500)
        let outputSize = CGSize(width: 1800, height: 600)
        let layout = CapturePreviewLayout(
            availableSize: viewportSize,
            outputSize: outputSize
        )
        let baseFieldOfView = Float.pi / 3
        let exportFieldOfView = layout.verticalFieldOfView(baseRadians: baseFieldOfView)
        let liveAspect = Float(viewportSize.width / viewportSize.height)
        let outputAspect = Float(outputSize.width / outputSize.height)
        let horizontalCoverage = Float(layout.previewSize.width / viewportSize.width)

        let previewHorizontalExtent = tan(baseFieldOfView / 2) * liveAspect * horizontalCoverage
        let exportHorizontalExtent = tan(exportFieldOfView / 2) * outputAspect

        #expect(abs(layout.previewSize.width / layout.previewSize.height - 3) < 0.000_1)
        #expect(abs(previewHorizontalExtent - exportHorizontalExtent) < 0.000_1)
    }

    @Test("watermark compositor adds export branding without resizing the frame")
    func watermarkCompositorPreservesFrameSize() throws {
        let original = try solidImage(red: 12, green: 24, blue: 36, width: 400, height: 120)
        let watermarked = try MediaExportWatermark.apply(to: original)
        let originalData = try #require(original.dataProvider?.data) as Data
        let watermarkedData = try #require(watermarked.dataProvider?.data) as Data

        #expect(watermarked.width == original.width)
        #expect(watermarked.height == original.height)
        #expect(watermarkedData != originalData)
    }

    @Test("shutdown estimates stop open recordings promptly and cap finite exports")
    func shutdownEstimatesAreBounded() {
        let openRecording = MediaExportShutdownEstimate(
            completesAutomatically: false,
            elapsedSeconds: 300,
            progress: 0,
            projectedMediaDurationSeconds: nil
        )
        let longFiniteExport = MediaExportShutdownEstimate(
            completesAutomatically: true,
            elapsedSeconds: 60,
            progress: 0.1,
            projectedMediaDurationSeconds: 15
        )

        #expect(openRecording.graceSeconds == 15)
        #expect(longFiniteExport.graceSeconds == MediaExportShutdownEstimate.maximumGraceSeconds)
    }

    @Test("export transaction publishes only completed output")
    @MainActor
    func exportTransactionCommitsCompletedOutput() throws {
        let fixture = try transactionFixture()
        defer { fixture.cleanup() }
        let finalURL = fixture.directory.appendingPathComponent("capture.gif")
        let transaction = try MediaExportTransaction(
            format: .gif,
            stagingDirectory: fixture.directory,
            recoveryLedger: fixture.ledger
        )
        try Data("complete".utf8).write(to: transaction.stagingURL)

        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
        transaction.markReady()
        try fixture.ledger.publish(transaction.stagingURL, to: finalURL)
        #expect(try Data(contentsOf: finalURL) == Data("complete".utf8))
    }

    @Test("export transaction replaces an existing destination only at commit")
    @MainActor
    func exportTransactionReplacesExistingDestination() throws {
        let fixture = try transactionFixture()
        defer { fixture.cleanup() }
        let finalURL = fixture.directory.appendingPathComponent("capture.gif")
        try Data("existing".utf8).write(to: finalURL)
        let transaction = try MediaExportTransaction(
            format: .gif,
            stagingDirectory: fixture.directory,
            recoveryLedger: fixture.ledger
        )
        try Data("replacement".utf8).write(to: transaction.stagingURL)

        #expect(try Data(contentsOf: finalURL) == Data("existing".utf8))
        transaction.markReady()
        try fixture.ledger.publish(transaction.stagingURL, to: finalURL)
        #expect(try Data(contentsOf: finalURL) == Data("replacement".utf8))
    }

    @Test("discarded export preserves an existing destination")
    @MainActor
    func discardedExportPreservesExistingDestination() throws {
        let fixture = try transactionFixture()
        defer { fixture.cleanup() }
        let finalURL = fixture.directory.appendingPathComponent("capture.gif")
        try Data("existing".utf8).write(to: finalURL)
        let transaction = try MediaExportTransaction(
            format: .gif,
            stagingDirectory: fixture.directory,
            recoveryLedger: fixture.ledger
        )
        try Data("partial".utf8).write(to: transaction.stagingURL)

        transaction.discard()

        #expect(try Data(contentsOf: finalURL) == Data("existing".utf8))
        #expect(!FileManager.default.fileExists(atPath: transaction.stagingURL.path))
    }

    @Test("recovery ledger removes staging files left by a crash")
    @MainActor
    func recoveryLedgerRemovesStaleArtifacts() throws {
        let fixture = try transactionFixture()
        defer { fixture.cleanup() }
        let staleURL = fixture.directory.appendingPathComponent(".capture.crashed.partial")
        try Data("partial".utf8).write(to: staleURL)
        fixture.ledger.register(staleURL)

        let recovery = fixture.ledger.recoverArtifacts()

        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        #expect(recovery.interruptedCount == 1)
    }

    @Test("recovery ledger preserves completed exports for the next launch")
    @MainActor
    func recoveryLedgerPreservesCompletedArtifacts() throws {
        let fixture = try transactionFixture()
        defer { fixture.cleanup() }
        let transaction = try MediaExportTransaction(
            format: .gif,
            stagingDirectory: fixture.directory,
            recoveryLedger: fixture.ledger
        )
        try Data("complete".utf8).write(to: transaction.stagingURL)
        transaction.markReady()

        let recovery = fixture.ledger.recoverArtifacts()

        #expect(recovery.readyURLs == [transaction.stagingURL])
        #expect(try Data(contentsOf: transaction.stagingURL) == Data("complete".utf8))
    }

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
        try encoder.add(try solidImage(red: 255, green: 0, blue: 0))
        try encoder.add(try solidImage(red: 0, green: 0, blue: 255))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 2)
    }

    @Test("GIF encoder streams a known-length animation")
    func gifEncoderStreamsKnownLengthAnimation() throws {
        let frameCount = 30
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-streaming-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: frameCount,
            framesPerSecond: 30,
            loopsForever: true
        )

        for index in 0..<frameCount {
            try encoder.add(try solidImage(
                red: UInt8(index * 8),
                green: UInt8(255 - index * 8),
                blue: 128,
                width: 128,
                height: 64
            ))
        }
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == frameCount)
        #expect(CGImageSourceCreateImageAtIndex(source, frameCount - 1, nil)?.width == 128)
    }

    @Test("ImageIO GIF encoder preserves complex frame content")
    func gifEncoderHandlesComplexFrame() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-complex-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: 1,
            framesPerSecond: 30,
            loopsForever: true
        )

        try encoder.add(try patternedImage(width: 512, height: 512))
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 512)
        let decodedPixels = try rgbaPixels(in: decoded)
        let nonWhitePixelCount = stride(from: 0, to: decodedPixels.count, by: 4).reduce(into: 0) { count, offset in
            if decodedPixels[offset] < 250 || decodedPixels[offset + 1] < 250 || decodedPixels[offset + 2] < 250 {
                count += 1
            }
        }
        #expect(nonWhitePixelCount > (512 * 512 * 3 / 4))
    }

    @Test("ImageIO GIF encoder discovers colors outside the old fixed palette")
    func gifEncoderPreservesAdaptiveColor() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-adaptive-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: 1,
            framesPerSecond: 30,
            loopsForever: true
        )

        try encoder.add(try solidImage(red: 17, green: 123, blue: 231, width: 64, height: 64))
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = try rgbaPixels(in: image)
        #expect(abs(Int(pixels[0]) - 17) <= 2)
        #expect(abs(Int(pixels[1]) - 123) <= 2)
        #expect(abs(Int(pixels[2]) - 231) <= 2)
    }

    @Test("GIF encoder rejects dimensions outside the format limit")
    func gifEncoderRejectsUnsupportedDimensions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-oversized-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: 1,
            framesPerSecond: 30,
            loopsForever: true
        )

        do {
            try encoder.add(try solidImage(
                red: 0,
                green: 0,
                blue: 0,
                width: Int(UInt16.max) + 1,
                height: 1
            ))
            Issue.record("Expected oversized GIF dimensions to be rejected")
        } catch MediaExportError.unsupportedGIFDimensions {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
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
        try encoder.add(try solidImage(red: 255, green: 0, blue: 0))
        try encoder.add(try solidImage(red: 0, green: 0, blue: 255))
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
        try encoder.add(try solidImage(red: 255, green: 0, blue: 0))
        try encoder.add(try solidImage(red: 0, green: 255, blue: 0))
        try encoder.add(try solidImage(red: 0, green: 0, blue: 255))
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
        try encoder.add(image)
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

        state.transportState = .stopped
        session.updateSimulationState(state)
        state.transportState = .running
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

    private func solidImage(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        width: Int = 2,
        height: Int = 2
    ) throws -> CGImage {
        let pixel: [UInt8] = [red, green, blue, 255]
        let pixels = Array(repeating: pixel, count: width * height).flatMap { $0 }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func patternedImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            var value = UInt32(truncatingIfNeeded: index &* 747_796_405 &+ 2_891_336_453)
            value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
            value = (value >> 22) ^ value
            let offset = index * 4
            pixels[offset] = UInt8(truncatingIfNeeded: value)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            pixels[offset + 3] = 255
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func rgbaPixels(in image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(rendered)
        return pixels
    }

    @MainActor
    private func transactionFixture() throws -> (
        directory: URL,
        ledger: MediaExportRecoveryLedger,
        cleanup: () -> Void
    ) {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-transaction-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsName = "ParticularityTests.MediaExport.\(id)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        let ledger = MediaExportRecoveryLedger(
            defaults: defaults,
            key: "pending",
            fileManager: .default
        )
        return (
            directory,
            ledger,
            {
                try? FileManager.default.removeItem(at: directory)
                defaults.removePersistentDomain(forName: defaultsName)
            }
        )
    }

    @MainActor
    private func firstParticle(in session: SimulationSession) -> ParticleState? {
        let renderState = session.renderState
        guard renderState.activeParticleCount > 0, let buffer = renderState.particleBuffer else { return nil }
        return buffer.contents().bindMemory(to: ParticleState.self, capacity: 1).pointee
    }
}
