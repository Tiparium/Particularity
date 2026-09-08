import AppKit
import CoreGraphics
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum MediaExportError: LocalizedError {
    case rendererUnavailable
    case playbackFrameUnavailable
    case playbackTimelineUnavailable
    case fixedStepUnavailable
    case destinationCreationFailed
    case destinationWriteFailed
    case destinationFinalizeFailed
    case destinationCommitFailed
    case unsupportedGIFDimensions
    case inconsistentFrameDimensions
    case watermarkCompositionFailed

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
        case .destinationWriteFailed:
            return "The media export could not be written. Check available disk space and try again."
        case .destinationFinalizeFailed:
            return "The media encoder could not finalize the exported file."
        case .destinationCommitFailed:
            return "The completed media could not be moved to the selected destination."
        case .unsupportedGIFDimensions:
            return "GIF dimensions must be between 1 and 65,535 pixels per side."
        case .inconsistentFrameDimensions:
            return "The media encoder received frames with inconsistent dimensions."
        case .watermarkCompositionFailed:
            return "The export watermark could not be rendered."
        }
    }
}

struct MediaExportShutdownEstimate {
    static let maximumGraceSeconds = 120.0

    let completesAutomatically: Bool
    let elapsedSeconds: Double
    let progress: Double
    let projectedMediaDurationSeconds: Double?

    var graceSeconds: Double {
        guard completesAutomatically else { return 15 }
        if progress > 0, progress < 1 {
            let projectedRemaining = elapsedSeconds * (1 - progress) / progress
            return min(Self.maximumGraceSeconds, max(10, projectedRemaining + 5))
        }
        if let projectedMediaDurationSeconds {
            return min(Self.maximumGraceSeconds, max(10, projectedMediaDurationSeconds + 5))
        }
        return 10
    }
}

@MainActor
final class MediaExportRecoveryLedger {
    static let shared = MediaExportRecoveryLedger()

    private let defaults: UserDefaults
    private let pendingKey: String
    private let readyKey: String
    private let fileManager: FileManager

    init(
        defaults: UserDefaults = .standard,
        key: String = "mediaExport.pendingStagingPaths",
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        pendingKey = key
        readyKey = "\(key).ready"
        self.fileManager = fileManager
    }

    func register(_ url: URL) {
        var paths = Set(defaults.stringArray(forKey: pendingKey) ?? [])
        paths.insert(url.path)
        defaults.set(Array(paths).sorted(), forKey: pendingKey)
        defaults.synchronize()
    }

    func markReady(_ url: URL) {
        remove(url.path, from: pendingKey)
        var paths = Set(defaults.stringArray(forKey: readyKey) ?? [])
        paths.insert(url.path)
        defaults.set(Array(paths).sorted(), forKey: readyKey)
        defaults.synchronize()
    }

    func unregister(_ url: URL) {
        remove(url.path, from: pendingKey)
        remove(url.path, from: readyKey)
        defaults.synchronize()
    }

    func recoverArtifacts() -> (readyURLs: [URL], interruptedCount: Int) {
        let pendingPaths = defaults.stringArray(forKey: pendingKey) ?? []
        var remainingPaths: [String] = []
        var interruptedCount = 0
        for path in pendingPaths {
            guard fileManager.fileExists(atPath: path) else { continue }
            do {
                try fileManager.removeItem(at: URL(fileURLWithPath: path))
                interruptedCount += 1
            } catch {
                remainingPaths.append(path)
            }
        }
        if remainingPaths.isEmpty {
            defaults.removeObject(forKey: pendingKey)
        } else {
            defaults.set(remainingPaths.sorted(), forKey: pendingKey)
        }

        let readyURLs = (defaults.stringArray(forKey: readyKey) ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { fileManager.fileExists(atPath: $0.path) }
        defaults.set(readyURLs.map(\.path).sorted(), forKey: readyKey)
        defaults.synchronize()
        return (readyURLs, interruptedCount)
    }

    func publish(_ stagingURL: URL, to finalURL: URL) throws {
        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: finalURL)
            }
            unregister(stagingURL)
        } catch {
            throw MediaExportError.destinationCommitFailed
        }
    }

    func discard(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                return false
            }
        }
        unregister(url)
        return true
    }

    private func remove(_ path: String, from key: String) {
        var paths = Set(defaults.stringArray(forKey: key) ?? [])
        paths.remove(path)
        if paths.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Array(paths).sorted(), forKey: key)
        }
    }
}

@MainActor
final class MediaExportTransaction {
    let stagingURL: URL

    private let fileManager: FileManager
    private let recoveryLedger: MediaExportRecoveryLedger
    private var isResolved = false

    init(
        format: MediaExportFormat,
        stagingDirectory: URL? = nil,
        fileManager: FileManager = .default,
        recoveryLedger: MediaExportRecoveryLedger = .shared
    ) throws {
        self.fileManager = fileManager
        self.recoveryLedger = recoveryLedger
        let directory = try stagingDirectory ?? Self.defaultStagingDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagingName = ".Particularity-\(UUID().uuidString).pending.\(format.fileExtension)"
        stagingURL = directory.appendingPathComponent(stagingName)
        recoveryLedger.register(stagingURL)
    }

    func markReady() {
        guard !isResolved else { return }
        recoveryLedger.markReady(stagingURL)
        isResolved = true
    }

    func discard() {
        guard !isResolved else { return }
        if recoveryLedger.discard(stagingURL) {
            isResolved = true
        }
    }

    private static func defaultStagingDirectory(fileManager: FileManager) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MediaExportError.destinationCreationFailed
        }
        return applicationSupport
            .appendingPathComponent("Particularity", isDirectory: true)
            .appendingPathComponent("Pending Media Exports", isDirectory: true)
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
    var supportsTransparency: Bool { self == .png || self == .gif }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .gif: return .gif
        case .mp4: return .mpeg4Movie
        }
    }

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "gif": self = .gif
        case "mp4": self = .mp4
        default: return nil
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
    var includesWatermark = true
    var transparentBackground = true

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

struct CapturePreviewLayout: Equatable, Sendable {
    let availableSize: CGSize
    let outputSize: CGSize

    var previewSize: CGSize {
        let horizontalBuffer = max(24, availableSize.width * 0.08)
        let verticalBuffer = max(16, availableSize.height * 0.05)
        let insetSize = CGSize(
            width: max(1, availableSize.width - horizontalBuffer * 2),
            height: max(1, availableSize.height - verticalBuffer * 2)
        )
        let outputAspect = max(0.01, outputSize.width / max(1, outputSize.height))
        let insetAspect = max(0.01, insetSize.width / max(1, insetSize.height))
        return insetAspect > outputAspect
            ? CGSize(width: insetSize.height * outputAspect, height: insetSize.height)
            : CGSize(width: insetSize.width, height: insetSize.width / outputAspect)
    }

    func verticalFieldOfView(baseRadians: Float) -> Float {
        let verticalCoverage = Float(previewSize.height / max(1, availableSize.height))
        return 2 * atan(tan(baseRadians / 2) * max(0.001, verticalCoverage))
    }
}

@MainActor
final class MediaExportStore: ObservableObject {
    @Published var settings = MediaExportSettings()
    @Published var capturePreviewEnabled = false
    @Published private(set) var isExporting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var completedExportCount = 0

    private weak var renderer: Renderer?
    private let session: SimulationSession
    let runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    let viewportStateStore: MainWindowViewportStateStore
    private var exportTask: Task<Void, Never>?
    private var stopRequested = false
    private var exportStartedAt: Date?
    private var activeExportCompletesAutomatically = false
    private var activeProjectedMediaDurationSeconds: Double?
    private var postExportActions: [() -> Void] = []
    private var completedExportURLs: [URL] = []
    private var isPreparingForTermination = false

    init(
        session: SimulationSession,
        viewportStateStore: MainWindowViewportStateStore,
        runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    ) {
        self.session = session
        self.viewportStateStore = viewportStateStore
        self.runtimeConfigCoordinator = runtimeConfigCoordinator
        let recovery = MediaExportRecoveryLedger.shared.recoverArtifacts()
        completedExportURLs = recovery.readyURLs
        completedExportCount = recovery.readyURLs.count
        if !recovery.readyURLs.isEmpty {
            statusMessage = recoveredExportStatus
        } else if recovery.interruptedCount > 0 {
            statusMessage = recovery.interruptedCount == 1
                ? "An interrupted export was discarded."
                : "\(recovery.interruptedCount) interrupted exports were discarded."
        }
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
        startExport(fromZero: fromZero)
    }

    func stopRecording() {
        guard isExporting else { return }
        stopRequested = true
        statusMessage = "Finishing"
    }

    func detachViewportAfterExport(_ session: SimulationSession) {
        guard isExporting else {
            session.detachViewport()
            return
        }
        postExportActions.append { session.detachViewport() }
    }

    func prepareForApplicationTermination() async {
        guard isExporting else { return }
        isPreparingForTermination = true
        if !activeExportCompletesAutomatically {
            stopRequested = true
            statusMessage = "Finishing before quit"
        } else {
            statusMessage = "Completing export before quit"
        }

        let estimate = MediaExportShutdownEstimate(
            completesAutomatically: activeExportCompletesAutomatically,
            elapsedSeconds: Date().timeIntervalSince(exportStartedAt ?? Date()),
            progress: progress,
            projectedMediaDurationSeconds: activeProjectedMediaDurationSeconds
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(estimate.graceSeconds))
        while isExporting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isExporting {
            stopRequested = true
            exportTask?.cancel()
        }
    }

    func saveCompletedExport() {
        guard !completedExportURLs.isEmpty, !isExporting else { return }
        presentSavePanel(for: completedExportURLs[0])
    }

    func discardCompletedExport() {
        guard !completedExportURLs.isEmpty, !isExporting else { return }
        let url = completedExportURLs[0]
        guard MediaExportRecoveryLedger.shared.discard(url) else {
            statusMessage = "The completed export could not be discarded."
            return
        }
        completedExportURLs.removeFirst()
        refreshCompletedExportStatus()
    }

    private func startExport(fromZero: Bool) {
        let request = settings
        let isPlayback = runtimeConfigCoordinator.activeModules.isPlayback
        stopRequested = false
        isExporting = true
        progress = 0
        statusMessage = "Preparing"
        exportStartedAt = Date()
        activeExportCompletesAutomatically = !request.format.isAnimated || (isPlayback && fromZero)
        activeProjectedMediaDurationSeconds = isPlayback && fromZero
            ? session.playbackTimelineState.durationSeconds
            : nil
        exportTask = Task { [weak self] in
            guard let self else { return }
            let transaction: MediaExportTransaction
            do {
                transaction = try MediaExportTransaction(format: request.format)
            } catch {
                self.finishExport(status: error.localizedDescription)
                return
            }
            var completedURL: URL?
            do {
                try await self.export(to: transaction.stagingURL, settings: request, fromZero: fromZero)
                try Task.checkCancellation()
                transaction.markReady()
                completedURL = transaction.stagingURL
                self.progress = 1
            } catch is CancellationError {
                transaction.discard()
                self.statusMessage = "Export cancelled"
            } catch {
                transaction.discard()
                self.statusMessage = error.localizedDescription
            }
            self.finishExport(status: completedURL == nil ? self.statusMessage : "Export ready to save")
            if let completedURL {
                self.completedExportURLs.append(completedURL)
                self.completedExportCount = self.completedExportURLs.count
                if !self.isPreparingForTermination {
                    self.presentSavePanel(for: completedURL)
                }
            }
        }
    }

    private func finishExport(status: String) {
        statusMessage = status
        isExporting = false
        exportTask = nil
        exportStartedAt = nil
        activeExportCompletesAutomatically = false
        activeProjectedMediaDurationSeconds = nil
        let actions = postExportActions
        postExportActions.removeAll()
        actions.forEach { $0() }
    }

    private func presentSavePanel(for stagingURL: URL) {
        guard let format = MediaExportFormat(fileExtension: stagingURL.pathExtension) else {
            statusMessage = "The completed export has an unknown format."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save \(format.title) Export"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Particularity.\(format.fileExtension)"
        let defaultDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/lab/exports/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        panel.directoryURL = defaultDirectory

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            refreshCompletedExportStatus()
            return
        }
        do {
            try MediaExportRecoveryLedger.shared.publish(stagingURL, to: destinationURL)
            completedExportURLs.removeAll { $0 == stagingURL }
            completedExportCount = completedExportURLs.count
            statusMessage = "Saved \(destinationURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func refreshCompletedExportStatus() {
        completedExportCount = completedExportURLs.count
        statusMessage = completedExportURLs.isEmpty ? "Ready" : recoveredExportStatus
    }

    private var recoveredExportStatus: String {
        completedExportURLs.count == 1
            ? "1 completed export is waiting to be saved."
            : "\(completedExportURLs.count) completed exports are waiting to be saved."
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
        let fieldOfView = captureFieldOfView(renderer: renderer, outputSize: settings.outputSize)
        var image = try renderer.captureImage(
            size: settings.outputSize,
            cameraState: renderer.renderedCameraState,
            showSimulationBounds: viewportStateStore.viewportState.showSimulationBounds,
            transparentBackground: settings.transparentBackground && settings.format.supportsTransparency,
            verticalFieldOfViewRadians: fieldOfView
        )
        if settings.includesWatermark {
            image = try MediaExportWatermark.apply(to: image)
        }
        try StillImageMediaEncoder.write(
            image,
            to: url,
            format: settings.format,
            jpegQuality: settings.jpegQuality
        )
    }

    private func exportGIF(to url: URL, settings: MediaExportSettings, fromZero: Bool) async throws {
        guard let renderer else { throw MediaExportError.rendererUnavailable }
        guard settings.width > 0,
              settings.height > 0,
              settings.width <= Int(UInt16.max),
              settings.height <= Int(UInt16.max) else {
            throw MediaExportError.unsupportedGIFDimensions
        }
        let fps = max(1, settings.framesPerSecond)
        let timeline = session.playbackTimelineState
        let isPlayback = runtimeConfigCoordinator.activeModules.isPlayback
        let timingMode = settings.timingMode
        let usesRealtimeFixedStep = !isPlayback && timingMode == .fixedStep
        let capturesFullLoop = isPlayback && fromZero
        let automaticFrameCount: Int?
        if capturesFullLoop {
            guard timeline.durationSeconds > 0 else { throw MediaExportError.playbackTimelineUnavailable }
            let captureDuration = timingMode == .live
                ? timeline.durationSeconds / max(0.000_001, timeline.playbackRate)
                : timeline.durationSeconds
            automaticFrameCount = MediaExportFramePlan(
                durationSeconds: captureDuration,
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
            if fromZero {
                runtimeConfigCoordinator.stopSimulation()
                runtimeConfigCoordinator.startSimulation()
            }
            await session.beginFixedStepCapture()
            fixedStepCaptureStarted = true
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

        let cameraState = renderer.renderedCameraState
        let showBounds = viewportStateStore.viewportState.showSimulationBounds
        let fieldOfView = captureFieldOfView(renderer: renderer, outputSize: settings.outputSize)
        let playbackStartSeconds = fromZero ? 0 : timeline.currentSeconds
        let clock = ContinuousClock()
        let startedAt = clock.now
        var frameIndex = 0
        var completedFixedSteps = 0

        while automaticFrameCount == nil || frameIndex < automaticFrameCount! {
            if stopRequested && frameIndex > 0 {
                break
            }
            try Task.checkCancellation()
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
                        try Task.checkCancellation()
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

            try autoreleasepool {
                var image = try renderer.captureImage(
                    size: settings.outputSize,
                    cameraState: cameraState,
                    showSimulationBounds: showBounds,
                    playbackTime: playbackTime,
                    transparentBackground: settings.transparentBackground && settings.format.supportsTransparency,
                    verticalFieldOfViewRadians: fieldOfView
                )
                if settings.includesWatermark {
                    image = try MediaExportWatermark.apply(to: image)
                }
                try encoder.add(image)
            }
            frameIndex += 1
            if let automaticFrameCount {
                progress = Double(frameIndex) / Double(automaticFrameCount)
                statusMessage = "Rendering \(frameIndex) of \(automaticFrameCount)"
            } else {
                progress = 0
                statusMessage = "Recording \(formattedDuration(Double(frameIndex) / Double(fps)))"
            }

            await Task.yield()
        }
        try Task.checkCancellation()
        guard frameIndex > 0 else { throw MediaExportError.destinationFinalizeFailed }
        try encoder.finalize()
    }

    private func formattedDuration(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func captureFieldOfView(renderer: Renderer, outputSize: CGSize) -> Float {
        guard renderer.logicalViewportSize.width > 1,
              renderer.logicalViewportSize.height > 1 else {
            return .pi / 3
        }
        return CapturePreviewLayout(
            availableSize: renderer.logicalViewportSize,
            outputSize: outputSize
        ).verticalFieldOfView(baseRadians: .pi / 3)
    }
}

struct CapturePreviewOverlay: View {
    let outputSize: CGSize
    let showsWatermark: Bool

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size
            let previewSize = CapturePreviewLayout(
                availableSize: available,
                outputSize: outputSize
            ).previewSize
            let exportFontSize = min(36, max(11, min(outputSize.width, outputSize.height) * 0.035))
            let previewScale = min(
                previewSize.width / max(1, outputSize.width),
                previewSize.height / max(1, outputSize.height)
            )
            let previewFontSize = exportFontSize * previewScale
            let edgePadding = max(8, exportFontSize * 0.65) * previewScale
            let horizontalInset = max(6, exportFontSize * 0.48) * previewScale
            let verticalInset = max(4, exportFontSize * 0.3) * previewScale

            ZStack(alignment: .bottomTrailing) {
                Rectangle()
                    .stroke(AppControlPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))

                if showsWatermark {
                    Text(MediaExportWatermark.text)
                        .font(.system(size: previewFontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .background {
                            RoundedRectangle(cornerRadius: verticalInset * 1.5)
                                .fill(.black.opacity(0.58))
                                .stroke(.white.opacity(0.16), lineWidth: max(0.5, previewFontSize * 0.04))
                        }
                        .padding(edgePadding)
                }
            }
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
                exportIntegerField("Width", value: binding(\.width), range: 1...Int.max)
                exportIntegerField("Height", value: binding(\.height), range: 1...Int.max)
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
                .labelsHidden()

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

            AppCheckboxToggle(
                "Made with Particularity",
                isOn: binding(\.includesWatermark),
                helpText: "Add a small watermark to the lower-right corner of exported media."
            )

            AppCheckboxToggle(
                "Transparent Background",
                isOn: binding(\.transparentBackground),
                helpText: store.settings.format.supportsTransparency
                    ? "Export empty scene areas with transparency instead of the viewport background."
                    : "The selected format does not support transparency."
            )
            .disabled(!store.settings.format.supportsTransparency)

            Divider()

            AppCheckboxToggle(
                "Capture Preview",
                isOn: $store.capturePreviewEnabled,
                helpText: "Outline the exact export aspect ratio in the viewport."
            )

            if !store.isExporting, store.completedExportCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.completedExportCount == 1
                        ? "A completed export is waiting to be saved."
                        : "\(store.completedExportCount) completed exports are waiting to be saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Save Export", action: store.saveCompletedExport)
                            .buttonStyle(AppFramedButtonStyle(.prominent))
                        Button("Discard", action: store.discardCompletedExport)
                            .buttonStyle(AppFramedButtonStyle(.destructive))
                    }
                }
            }

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

enum MediaExportWatermark {
    static let text = "Made with Particularity"

    static func apply(to image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw MediaExportError.watermarkCompositionFailed
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let shortestEdge = CGFloat(min(width, height))
        let fontSize = min(36, max(11, shortestEdge * 0.035))
        let font = CTFontCreateWithName("SF Pro Text Semibold" as CFString, fontSize, nil)
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(
                    gray: 1,
                    alpha: 0.94
                ),
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedText)
        let textBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let edgePadding = max(8, fontSize * 0.65)
        let horizontalInset = max(6, fontSize * 0.48)
        let verticalInset = max(4, fontSize * 0.3)
        let baselineX = CGFloat(width) - edgePadding - textBounds.width - textBounds.minX
        let baselineY = edgePadding - textBounds.minY
        let visibleTextRect = CGRect(
            x: baselineX + textBounds.minX,
            y: baselineY + textBounds.minY,
            width: textBounds.width,
            height: textBounds.height
        )
        let plateRect = visibleTextRect.insetBy(dx: -horizontalInset, dy: -verticalInset)
        let platePath = CGPath(
            roundedRect: plateRect,
            cornerWidth: verticalInset * 1.5,
            cornerHeight: verticalInset * 1.5,
            transform: nil
        )
        context.addPath(platePath)
        context.setFillColor(CGColor(gray: 0, alpha: 0.58))
        context.fillPath()
        context.addPath(platePath)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.setLineWidth(max(1, fontSize * 0.04))
        context.strokePath()

        context.textMatrix = .identity
        context.textPosition = CGPoint(x: baselineX, y: baselineY)
        CTLineDraw(line, context)

        guard let result = context.makeImage() else {
            throw MediaExportError.watermarkCompositionFailed
        }
        return result
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
