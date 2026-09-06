import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum MediaExportError: LocalizedError {
    case rendererUnavailable
    case playbackFrameUnavailable
    case playbackTimelineUnavailable
    case destinationCreationFailed
    case destinationFinalizeFailed

    var errorDescription: String? {
        switch self {
        case .rendererUnavailable:
            return "The viewport renderer is not available."
        case .playbackFrameUnavailable:
            return "The active Trinity could not produce the requested playback frame."
        case .playbackTimelineUnavailable:
            return "Stable render-pass capture currently requires an active playback Trinity."
        case .destinationCreationFailed:
            return "The GIF destination could not be created."
        case .destinationFinalizeFailed:
            return "The GIF encoder could not finalize the exported file."
        }
    }
}

enum MediaCaptureTimingMode: String, CaseIterable, Identifiable, Sendable {
    case renderPass
    case live

    var id: String { rawValue }
    var title: String {
        switch self {
        case .renderPass: return "Render Pass"
        case .live: return "Live"
        }
    }
}

struct MediaExportSettings: Equatable, Sendable {
    var width = 1800
    var height = 600
    var framesPerSecond = 30
    var updatesPerSecond = 60
    var durationSeconds = 5.0
    var captureFullPlaybackLoop = true
    var timingMode = MediaCaptureTimingMode.renderPass
    var gifLoopsForever = true

    var outputSize: CGSize {
        CGSize(width: max(1, width), height: max(1, height))
    }
}

struct MediaExportFramePlan: Equatable, Sendable {
    let durationSeconds: Double
    let framesPerSecond: Int
    let updatesPerSecond: Int

    var frameCount: Int {
        max(1, Int((durationSeconds * Double(framesPerSecond)).rounded(.up)))
    }

    func presentationTime(for frameIndex: Int) -> Double {
        Double(frameIndex) / Double(framesPerSecond)
    }

    func playbackTime(for frameIndex: Int) -> Double {
        let time = presentationTime(for: frameIndex)
        return floor(time * Double(updatesPerSecond) + 0.000_001) / Double(updatesPerSecond)
    }
}

@MainActor
final class MediaExportStore: ObservableObject {
    @Published var settings = MediaExportSettings()
    @Published var capturePreviewEnabled = false
    @Published private(set) var isExporting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusMessage = "Ready"

    private weak var renderer: Renderer?
    private let session: SimulationSession
    let viewportStateStore: MainWindowViewportStateStore
    private var exportTask: Task<Void, Never>?

    init(session: SimulationSession, viewportStateStore: MainWindowViewportStateStore) {
        self.session = session
        self.viewportStateStore = viewportStateStore
    }

    func attach(renderer: Renderer) {
        self.renderer = renderer
    }

    func detach(renderer: Renderer?) {
        guard self.renderer === renderer else { return }
        self.renderer = nil
    }

    func chooseAndExportGIF() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export GIF"
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Particularity.gif"

        let defaultDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/lab/exports/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        panel.directoryURL = defaultDirectory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startGIFExport(to: url)
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    var hasPlaybackTimeline: Bool {
        session.playbackTimelineState.durationSeconds > 0
    }

    private func startGIFExport(to url: URL) {
        let request = settings
        isExporting = true
        progress = 0
        statusMessage = "Preparing"
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.exportGIF(to: url, settings: request)
                guard !Task.isCancelled else {
                    self.statusMessage = "Cancelled"
                    self.isExporting = false
                    return
                }
                self.progress = 1
                self.statusMessage = "Saved \(url.lastPathComponent)"
            } catch is CancellationError {
                self.statusMessage = "Cancelled"
            } catch {
                self.statusMessage = error.localizedDescription
            }
            self.isExporting = false
            self.exportTask = nil
        }
    }

    private func exportGIF(to url: URL, settings: MediaExportSettings) async throws {
        guard let renderer else { throw MediaExportError.rendererUnavailable }
        let fps = max(1, settings.framesPerSecond)
        let timeline = session.playbackTimelineState
        let duration: Double
        let capturesFullLoop = settings.timingMode == .renderPass && settings.captureFullPlaybackLoop
        if capturesFullLoop {
            guard timeline.durationSeconds > 0 else { throw MediaExportError.playbackTimelineUnavailable }
            duration = timeline.durationSeconds
        } else {
            duration = max(1.0 / Double(fps), settings.durationSeconds)
        }
        if settings.timingMode == .renderPass, timeline.durationSeconds <= 0 {
            throw MediaExportError.playbackTimelineUnavailable
        }

        let framePlan = MediaExportFramePlan(
            durationSeconds: duration,
            framesPerSecond: fps,
            updatesPerSecond: max(1, settings.updatesPerSecond)
        )
        let frameCount = framePlan.frameCount
        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: frameCount,
            frameDelay: 1.0 / Double(fps),
            loopsForever: settings.gifLoopsForever
        )
        let originalSimulationState = session.simulationState
        let pausesRuntime = settings.timingMode == .renderPass
            && originalSimulationState.transportState == .running
        if pausesRuntime {
            var pausedState = originalSimulationState
            pausedState.transportState = .paused
            session.updateSimulationState(pausedState)
        }
        defer {
            if pausesRuntime {
                session.updateSimulationState(originalSimulationState)
            }
        }

        let cameraState = viewportStateStore.viewportState.camera
        let showBounds = viewportStateStore.viewportState.showSimulationBounds
        let clock = ContinuousClock()
        let startedAt = clock.now

        for frameIndex in 0..<frameCount {
            try Task.checkCancellation()
            let presentationTime = framePlan.presentationTime(for: frameIndex)
            let playbackTime: Double?
            switch settings.timingMode {
            case .renderPass:
                playbackTime = framePlan.playbackTime(for: frameIndex)
            case .live:
                playbackTime = nil
                let deadline = startedAt.advanced(by: .seconds(presentationTime))
                try await clock.sleep(until: deadline)
            }

            let image = try renderer.captureImage(
                size: settings.outputSize,
                cameraState: cameraState,
                showSimulationBounds: showBounds,
                playbackTime: playbackTime
            )
            encoder.add(image)
            progress = Double(frameIndex + 1) / Double(frameCount)
            statusMessage = "Rendering \(frameIndex + 1) of \(frameCount)"
            await Task.yield()
        }
        try encoder.finalize()
    }
}

struct CapturePreviewOverlay: View {
    let outputSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size
            let outputAspect = max(0.01, outputSize.width / outputSize.height)
            let availableAspect = max(0.01, available.width / available.height)
            let previewSize = availableAspect > outputAspect
                ? CGSize(width: available.height * outputAspect, height: available.height)
                : CGSize(width: available.width, height: available.width / outputAspect)

            Rectangle()
                .stroke(AppControlPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .frame(width: previewSize.width, height: previewSize.height)
                .position(x: available.width / 2, y: available.height / 2)
        }
    }
}

struct MediaExportPanel: View {
    @ObservedObject var store: MediaExportStore

    private var isRenderPass: Bool { store.settings.timingMode == .renderPass }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Capture", selection: binding(\.timingMode)) {
                ForEach(MediaCaptureTimingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Group {
                exportIntegerField("Width", value: binding(\.width), range: 1...8192)
                exportIntegerField("Height", value: binding(\.height), range: 1...8192)
                exportIntegerField("Frames / Second", value: binding(\.framesPerSecond), range: 1...120)
                exportIntegerField("Updates / Second", value: binding(\.updatesPerSecond), range: 1...240)
                    .disabled(!isRenderPass)
            }

            HStack {
                Text("Duration")
                Spacer()
                TextField("Seconds", value: binding(\.durationSeconds), format: .number.precision(.fractionLength(1)))
                    .frame(width: 72)
                Text("sec")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .disabled(isRenderPass && store.settings.captureFullPlaybackLoop)

            AppCheckboxToggle(
                "Capture Full Playback Loop",
                isOn: binding(\.captureFullPlaybackLoop),
                helpText: "Render exactly one loop, starting at time zero."
            )
            .disabled(!isRenderPass || !store.hasPlaybackTimeline)

            AppCheckboxToggle(
                "Loop GIF",
                isOn: binding(\.gifLoopsForever),
                helpText: "Repeat the exported GIF indefinitely."
            )

            Divider()

            AppCheckboxToggle(
                "Capture Preview",
                isOn: $store.capturePreviewEnabled,
                helpText: "Outline the exact export aspect ratio in the viewport."
            )

            AppCheckboxToggle(
                "Show Simulation Bounds",
                isOn: boundsVisibilityBinding,
                helpText: "Show the simulation bounds in both the viewport and exported media."
            )

            if store.isExporting {
                ProgressView(value: store.progress)
                HStack {
                    Text(store.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel", action: store.cancelExport)
                        .buttonStyle(AppFramedButtonStyle(.destructive))
                }
            } else {
                Text(store.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Export GIF", action: store.chooseAndExportGIF)
                    .buttonStyle(AppFramedButtonStyle(.prominent))
            }
        }
    }

    private var boundsVisibilityBinding: Binding<Bool> {
        Binding(
            get: { store.viewportStateStore.viewportState.showSimulationBounds },
            set: { store.viewportStateStore.setSimulationBoundsVisible($0) }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MediaExportSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { nextValue in
                var settings = store.settings
                settings[keyPath: keyPath] = nextValue
                store.settings = settings
            }
        )
    }

    private func exportIntegerField(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .frame(width: 72)
                .onChange(of: value.wrappedValue) { _, newValue in
                    value.wrappedValue = min(range.upperBound, max(range.lowerBound, newValue))
                }
        }
        .font(.caption)
    }
}

final class GIFMediaEncoder {
    private let destination: CGImageDestination
    private let frameProperties: CFDictionary

    init(url: URL, frameCount: Int, frameDelay: Double, loopsForever: Bool) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw MediaExportError.destinationCreationFailed
        }
        self.destination = destination
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopsForever ? 0 : 1,
            ],
        ] as CFDictionary)
        frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
            ],
        ] as CFDictionary
    }

    func add(_ image: CGImage) {
        CGImageDestinationAddImage(destination, image, frameProperties)
    }

    func finalize() throws {
        guard CGImageDestinationFinalize(destination) else {
            throw MediaExportError.destinationFinalizeFailed
        }
    }
}
