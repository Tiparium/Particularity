import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum MediaExportError: LocalizedError {
    case rendererUnavailable
    case playbackFrameUnavailable
    case playbackTimelineUnavailable
    case fixedStepUnavailable
    case destinationCreationFailed
    case destinationFinalizeFailed

    var errorDescription: String? {
        switch self {
        case .rendererUnavailable:
            return "The viewport renderer is not available."
        case .playbackFrameUnavailable:
            return "The active Trinity could not produce the requested playback frame."
        case .playbackTimelineUnavailable:
            return "Fixed-step playback capture requires an active playback timeline."
        case .fixedStepUnavailable:
            return "The active realtime Trinity could not complete a fixed simulation step."
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
    case fixedStep
    case live

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixedStep: return "Fixed-Step Render"
        case .live: return "Live Recording"
        }
    }
}

struct MediaExportSettings: Equatable, Sendable {
    var format = MediaExportFormat.gif
    var width = 1800
    var height = 600
    var framesPerSecond = 30
    var updatesPerSecond = 60
    var timingMode = MediaCaptureTimingMode.fixedStep
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

    func targetUpdateCount(for frameIndex: Int) -> Int {
        Int(floor(presentationTime(for: frameIndex) * Double(updatesPerSecond) + 0.000_001))
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
    private var stopRequested = false

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

    func chooseAndExport(fromZero: Bool = false) {
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
        startExport(to: url, fromZero: fromZero)
    }

    func stopRecording() {
        guard isExporting else { return }
        stopRequested = true
        statusMessage = "Finishing"
    }

    private func startExport(to url: URL, fromZero: Bool) {
        let request = settings
        stopRequested = false
        isExporting = true
        progress = 0
        statusMessage = "Preparing"
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.export(to: url, settings: request, fromZero: fromZero)
                self.progress = 1
                self.statusMessage = "Saved \(url.lastPathComponent)"
            } catch {
                self.statusMessage = error.localizedDescription
            }
            self.isExporting = false
            self.exportTask = nil
        }
    }

    private func export(to url: URL, settings: MediaExportSettings, fromZero: Bool) async throws {
        switch settings.format {
        case .png, .jpeg:
            try exportStillImage(to: url, settings: settings)
        case .gif:
            try await exportGIF(to: url, settings: settings, fromZero: fromZero)
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

    private func exportGIF(to url: URL, settings: MediaExportSettings, fromZero: Bool) async throws {
        guard let renderer else { throw MediaExportError.rendererUnavailable }
        let fps = max(1, settings.framesPerSecond)
        let timeline = session.playbackTimelineState
        let isPlayback = runtimeConfigCoordinator.activeModules.isPlayback
        let timingMode = settings.timingMode
        let usesRealtimeFixedStep = !isPlayback && timingMode == .fixedStep
        let capturesFullLoop = isPlayback && fromZero
        let automaticFrameCount: Int?
        if capturesFullLoop && timingMode == .fixedStep {
            guard timeline.durationSeconds > 0 else { throw MediaExportError.playbackTimelineUnavailable }
            automaticFrameCount = MediaExportFramePlan(
                durationSeconds: timeline.durationSeconds,
                framesPerSecond: fps,
                updatesPerSecond: max(1, settings.updatesPerSecond)
            ).frameCount
        } else {
            automaticFrameCount = nil
        }
        if isPlayback, timingMode == .fixedStep, timeline.durationSeconds <= 0 {
            throw MediaExportError.playbackTimelineUnavailable
        }

        let framePlan = MediaExportFramePlan(
            durationSeconds: timeline.durationSeconds,
            framesPerSecond: fps,
            updatesPerSecond: max(1, settings.updatesPerSecond)
        )
        let encoder = try GIFMediaEncoder(
            url: url,
            frameCount: automaticFrameCount ?? 0,
            framesPerSecond: min(100, fps),
            loopsForever: settings.gifLoopsForever
        )
        let originalSimulationState = session.simulationState
        let originalPlaybackTime = timeline.currentSeconds
        let pausesRuntime = isPlayback
            && timingMode == .fixedStep
            && originalSimulationState.transportState == .running
        let restartsRuntime = fromZero && timingMode == .live
        var fixedStepCaptureStarted = false
        if pausesRuntime {
            var pausedState = originalSimulationState
            pausedState.transportState = .paused
            session.updateSimulationState(pausedState)
        }
        if restartsRuntime {
            runtimeConfigCoordinator.stopSimulation()
            runtimeConfigCoordinator.startSimulation()
        }
        if usesRealtimeFixedStep {
            await session.beginFixedStepCapture()
            fixedStepCaptureStarted = true
            if fromZero {
                runtimeConfigCoordinator.stopSimulation()
                runtimeConfigCoordinator.startSimulation()
            }
            guard await session.prepareFixedStepFrame() else {
                session.finishFixedStepCapture()
                fixedStepCaptureStarted = false
                throw MediaExportError.fixedStepUnavailable
            }
        }
        defer {
            if fixedStepCaptureStarted {
                session.finishFixedStepCapture()
            }
            if pausesRuntime {
                session.updateSimulationState(originalSimulationState)
            }
            if isPlayback && fromZero {
                session.seekPlayback(to: originalPlaybackTime)
                if timingMode == .live {
                    switch originalSimulationState.transportState {
                    case .stopped:
                        runtimeConfigCoordinator.stopSimulation()
                    case .paused:
                        if runtimeConfigCoordinator.transportState == .running {
                            runtimeConfigCoordinator.togglePausePlay()
                        }
                    case .running:
                        break
                    }
                }
            }
        }

        let cameraState = viewportStateStore.viewportState.camera
        let showBounds = viewportStateStore.viewportState.showSimulationBounds
        let playbackStartSeconds = fromZero ? 0 : timeline.currentSeconds
        let clock = ContinuousClock()
        let startedAt = clock.now
        var frameIndex = 0
        var previousLivePlaybackTime = session.playbackTimelineState.currentSeconds
        var livePlaybackHasAdvanced = false
        var completedFixedSteps = 0

        while !stopRequested && (automaticFrameCount == nil || frameIndex < automaticFrameCount!) {
            let presentationTime = framePlan.presentationTime(for: frameIndex)
            let playbackTime: Double?
            switch timingMode {
            case .fixedStep:
                if automaticFrameCount == nil {
                    let deadline = startedAt.advanced(by: .seconds(presentationTime))
                    try await clock.sleep(until: deadline)
                }
                if isPlayback {
                    let requestedTime = playbackStartSeconds + framePlan.playbackTime(for: frameIndex)
                    if timeline.isLooping, timeline.durationSeconds > 0 {
                        playbackTime = requestedTime.truncatingRemainder(dividingBy: timeline.durationSeconds)
                    } else {
                        playbackTime = min(requestedTime, timeline.durationSeconds)
                    }
                } else {
                    let targetSteps = framePlan.targetUpdateCount(for: frameIndex)
                    while completedFixedSteps < targetSteps {
                        guard await session.advanceFixedStep() else {
                            throw MediaExportError.fixedStepUnavailable
                        }
                        completedFixedSteps += 1
                    }
                    playbackTime = nil
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
            frameIndex += 1
            if let automaticFrameCount {
                progress = Double(frameIndex) / Double(automaticFrameCount)
                statusMessage = "Rendering \(frameIndex) of \(automaticFrameCount)"
            } else {
                progress = 0
                statusMessage = "Recording \(formattedDuration(Double(frameIndex) / Double(fps)))"
            }

            if capturesFullLoop && timingMode == .live {
                let currentTime = session.playbackTimelineState.currentSeconds
                livePlaybackHasAdvanced = livePlaybackHasAdvanced || currentTime > previousLivePlaybackTime
                if livePlaybackHasAdvanced && currentTime < previousLivePlaybackTime {
                    break
                }
                if !session.playbackTimelineState.isLooping,
                   currentTime >= session.playbackTimelineState.durationSeconds {
                    break
                }
                previousLivePlaybackTime = currentTime
            }
            await Task.yield()
        }
        guard frameIndex > 0 else { throw MediaExportError.destinationFinalizeFailed }
        try encoder.finalize()
    }

    private func formattedDuration(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
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

    private var isFixedStep: Bool { store.settings.timingMode == .fixedStep }
    private var isAnimated: Bool { store.settings.format.isAnimated }

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
                Text("Recording Method")
                    .font(.caption.weight(.semibold))
                Picker("Recording Method", selection: binding(\.timingMode)) {
                    ForEach(MediaCaptureTimingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                exportIntegerField("Frames / Second", value: binding(\.framesPerSecond), range: 1...120)
                if isFixedStep {
                    exportIntegerField("Updates / Second", value: binding(\.updatesPerSecond), range: 1...240)
                }

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
                if store.progress > 0 {
                    ProgressView(value: store.progress)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                HStack {
                    Text(store.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop Recording", action: store.stopRecording)
                        .buttonStyle(AppFramedButtonStyle(.destructive))
                }
            } else {
                Text(store.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if isAnimated {
                    HStack(spacing: 8) {
                        Button("Record Now") {
                            store.chooseAndExport(fromZero: false)
                        }
                        .buttonStyle(AppFramedButtonStyle(.prominent))

                        Button("Record From Zero") {
                            store.chooseAndExport(fromZero: true)
                        }
                        .buttonStyle(AppFramedButtonStyle())
                        .disabled(!runtimeConfigCoordinator.validationReport.canStart)
                    }
                } else {
                    Button("Export \(store.settings.format.title)") {
                        store.chooseAndExport()
                    }
                    .buttonStyle(AppFramedButtonStyle(.prominent))
                }
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
    private let framesPerSecond: Int
    private var nextFrameIndex = 0

    init(url: URL, frameCount: Int, framesPerSecond: Int, loopsForever: Bool) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw MediaExportError.destinationCreationFailed
        }
        self.destination = destination
        self.framesPerSecond = min(100, max(1, framesPerSecond))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopsForever ? 0 : 1,
            ],
        ] as CFDictionary)
    }

    func add(_ image: CGImage) {
        let startCentiseconds = Int(
            (Double(nextFrameIndex) * 100.0 / Double(framesPerSecond)).rounded()
        )
        let endCentiseconds = Int(
            (Double(nextFrameIndex + 1) * 100.0 / Double(framesPerSecond)).rounded()
        )
        let delay = Double(max(1, endCentiseconds - startCentiseconds)) / 100.0
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, frameProperties)
        nextFrameIndex += 1
    }

    func finalize() throws {
        guard CGImageDestinationFinalize(destination) else {
            throw MediaExportError.destinationFinalizeFailed
        }
    }
}
