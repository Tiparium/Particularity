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
            return "The media destination could not be created."
        case .destinationFinalizeFailed:
            return "The media encoder could not finalize the exported file."
        }
    }
}

enum MediaExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case gif
    case mp4

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .gif: return "GIF"
        case .mp4: return "MP4"
        }
    }

    var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }
    var isAnimated: Bool { self == .gif || self == .mp4 }
    var isAvailable: Bool { self != .mp4 }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .gif: return .gif
        case .mp4: return .mpeg4Movie
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
    var format = MediaExportFormat.gif
    var width = 1800
    var height = 600
    var framesPerSecond = 30
    var updatesPerSecond = 60
    var durationSeconds = 5.0
    var captureFullPlaybackLoop = true
    var timingMode = MediaCaptureTimingMode.renderPass
    var gifLoopsForever = true
    var jpegQuality = 0.9

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
    let runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    let viewportStateStore: MainWindowViewportStateStore
    private var exportTask: Task<Void, Never>?

    init(
        session: SimulationSession,
        viewportStateStore: MainWindowViewportStateStore,
        runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    ) {
        self.session = session
        self.viewportStateStore = viewportStateStore
        self.runtimeConfigCoordinator = runtimeConfigCoordinator
    }

    func attach(renderer: Renderer) {
        self.renderer = renderer
    }

    func detach(renderer: Renderer?) {
        guard self.renderer === renderer else { return }
        self.renderer = nil
    }

    func chooseAndExport() {
        guard !isExporting else { return }
        let format = settings.format
        guard format.isAvailable else {
            statusMessage = "MP4 export is not implemented yet."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export \(format.title)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Particularity.\(format.fileExtension)"

        let defaultDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/lab/exports/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        panel.directoryURL = defaultDirectory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startExport(to: url)
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func startExport(to url: URL) {
        let request = settings
        isExporting = true
        progress = 0
        statusMessage = "Preparing"
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.export(to: url, settings: request)
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

    private func export(to url: URL, settings: MediaExportSettings) async throws {
        switch settings.format {
        case .png, .jpeg:
            try exportStillImage(to: url, settings: settings)
        case .gif:
            try await exportGIF(to: url, settings: settings)
        case .mp4:
            throw MediaExportError.destinationCreationFailed
        }
    }

    private func exportStillImage(to url: URL, settings: MediaExportSettings) throws {
        guard let renderer else { throw MediaExportError.rendererUnavailable }
        let image = try renderer.captureImage(
            size: settings.outputSize,
            cameraState: viewportStateStore.viewportState.camera,
            showSimulationBounds: viewportStateStore.viewportState.showSimulationBounds
        )
        try StillImageMediaEncoder.write(
            image,
            to: url,
            format: settings.format,
            jpegQuality: settings.jpegQuality
        )
    }

    private func exportGIF(to url: URL, settings: MediaExportSettings) async throws {
        guard let renderer else { throw MediaExportError.rendererUnavailable }
        let fps = max(1, settings.framesPerSecond)
        let timeline = session.playbackTimelineState
        let duration: Double
        let isPlayback = runtimeConfigCoordinator.activeModules.isPlayback
        let capturesFullLoop = isPlayback
            && settings.timingMode == .renderPass
            && settings.captureFullPlaybackLoop
        if capturesFullLoop {
            guard timeline.durationSeconds > 0 else { throw MediaExportError.playbackTimelineUnavailable }
            duration = timeline.durationSeconds
        } else {
            duration = max(1.0 / Double(fps), settings.durationSeconds)
        }
        if settings.timingMode == .renderPass, !isPlayback || timeline.durationSeconds <= 0 {
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
        let playbackStartSeconds = capturesFullLoop ? 0 : timeline.currentSeconds
        let clock = ContinuousClock()
        let startedAt = clock.now

        for frameIndex in 0..<frameCount {
            try Task.checkCancellation()
            let presentationTime = framePlan.presentationTime(for: frameIndex)
            let playbackTime: Double?
            switch settings.timingMode {
            case .renderPass:
                let requestedTime = playbackStartSeconds + framePlan.playbackTime(for: frameIndex)
                if timeline.isLooping, timeline.durationSeconds > 0 {
                    playbackTime = requestedTime.truncatingRemainder(dividingBy: timeline.durationSeconds)
                } else {
                    playbackTime = min(requestedTime, timeline.durationSeconds)
                }
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
    @ObservedObject private var runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator

    init(store: MediaExportStore) {
        self.store = store
        _runtimeConfigCoordinator = ObservedObject(wrappedValue: store.runtimeConfigCoordinator)
    }

    private var isRenderPass: Bool { store.settings.timingMode == .renderPass }
    private var isAnimated: Bool { store.settings.format.isAnimated }
    private var isPlayback: Bool { runtimeConfigCoordinator.activeModules.isPlayback }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Format")
                Spacer()
                Menu {
                    ForEach(MediaExportFormat.allCases) { format in
                        Button(format.isAvailable ? format.title : "\(format.title) - Coming Later") {
                            var settings = store.settings
                            settings.format = format
                            store.settings = settings
                        }
                        .disabled(!format.isAvailable)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(store.settings.format.title)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(.caption)

            Group {
                exportIntegerField("Width", value: binding(\.width), range: 1...8192)
                exportIntegerField("Height", value: binding(\.height), range: 1...8192)
            }

            if store.settings.format == .jpeg {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text("\(Int(store.settings.jpegQuality * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: binding(\.jpegQuality), in: 0.05...1)
                }
                .font(.caption)
            }

            if isAnimated {
                Picker("Capture", selection: binding(\.timingMode)) {
                    ForEach(MediaCaptureTimingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                exportIntegerField("Frames / Second", value: binding(\.framesPerSecond), range: 1...120)
                exportIntegerField("Updates / Second", value: binding(\.updatesPerSecond), range: 1...240)
                    .disabled(!isRenderPass)

                HStack {
                    Text("Duration")
                    Spacer()
                    TextField("Seconds", value: binding(\.durationSeconds), format: .number.precision(.fractionLength(1)))
                        .frame(width: 72)
                    Text("sec")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .disabled(isRenderPass && isPlayback && store.settings.captureFullPlaybackLoop)

                AppCheckboxToggle(
                    "Capture Full Playback Loop",
                    isOn: binding(\.captureFullPlaybackLoop),
                    helpText: "Reset playback to zero and render exactly one complete loop."
                )
                .disabled(!isRenderPass || !isPlayback)

                if store.settings.format == .gif {
                    AppCheckboxToggle(
                        "Loop GIF",
                        isOn: binding(\.gifLoopsForever),
                        helpText: "Repeat the exported GIF indefinitely."
                    )
                }
            }

            Divider()

            AppCheckboxToggle(
                "Capture Preview",
                isOn: $store.capturePreviewEnabled,
                helpText: "Outline the exact export aspect ratio in the viewport."
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
                Button("Export \(store.settings.format.title)", action: store.chooseAndExport)
                    .buttonStyle(AppFramedButtonStyle(.prominent))
            }
        }
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

enum StillImageMediaEncoder {
    static func write(
        _ image: CGImage,
        to url: URL,
        format: MediaExportFormat,
        jpegQuality: Double
    ) throws {
        guard format == .png || format == .jpeg,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                format.contentType.identifier as CFString,
                1,
                nil
              ) else {
            throw MediaExportError.destinationCreationFailed
        }
        let properties: CFDictionary? = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: min(1, max(0, jpegQuality))] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaExportError.destinationFinalizeFailed
        }
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
