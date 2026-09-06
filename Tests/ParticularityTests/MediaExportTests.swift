import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import Testing
@testable import Particularity

@Suite("Media export")
struct MediaExportTests {
    @Test("render-pass frame plan excludes the duplicate loop endpoint")
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

    @Test("render-pass frame plan quantizes playback to update boundaries")
    func framePlanQuantizesPlaybackTime() {
        let plan = MediaExportFramePlan(
            durationSeconds: 1,
            framesPerSecond: 24,
            updatesPerSecond: 60
        )

        #expect(plan.playbackTime(for: 1) == 2.0 / 60.0)
    }

    @Test("GIF encoder writes all requested frames")
    func gifEncoderWritesFrames() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("particularity-export-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: 2,
            frameDelay: 1.0 / 30.0,
            loopsForever: true
        )
        encoder.add(try solidImage(red: 255, green: 0, blue: 0))
        encoder.add(try solidImage(red: 0, green: 0, blue: 255))
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 2)
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
        let encoder = try GIFMediaEncoder(url: url, frameCount: 1, frameDelay: 1.0 / 30.0, loopsForever: true)
        encoder.add(image)
        try encoder.finalize()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 320)
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
}
