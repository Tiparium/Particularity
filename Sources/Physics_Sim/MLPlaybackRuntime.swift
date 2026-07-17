import Foundation
import simd

final class MLPlaybackRuntime: ParticlePlaybackRuntime {
    static let fixturePath = "Sources/lab/data/derived/ml_playback_neuron_sweeps_v3/e08_run001_layers15.mlpb"

    private let fixture: MLPlaybackFixture
    private var settings = MLPlaybackViewportSettings(isActive: true)

    var timeline: PlaybackTimelineState {
        PlaybackTimelineState(
            currentSeconds: 0,
            durationSeconds: fixture.durationSeconds,
            playbackRate: 1,
            isLooping: true,
            sampleCount: fixture.frames.count,
            currentSampleIndex: nil
        )
    }

    init?() {
        guard let fixture = MLPlaybackFixtureLoader.loadFixture() else {
            return nil
        }
        self.fixture = fixture
    }

    func updateSettings(_ settings: MLPlaybackViewportSettings) {
        self.settings = settings
    }

    func frame(at seconds: Double) -> PlaybackParticleFrame {
        fixture.frame(at: seconds, settings: settings)
    }
}

private final class MLPlaybackFixture {
    let url: URL
    let particleCount: Int
    let durationSeconds: Double
    let frameByteCount: UInt64
    let frames: [MLPlaybackFrameIndex]
    let isLayeredFixture: Bool
    private let handle: FileHandle
    private var cachedFrames: [MLPlaybackFrameCacheKey: [ParticleState]] = [:]
    private var cachedFrameOrder: [MLPlaybackFrameCacheKey] = []
    private let cacheLimit = 8

    init(
        url: URL,
        particleCount: Int,
        durationSeconds: Double,
        frameByteCount: UInt64,
        frames: [MLPlaybackFrameIndex],
        isLayeredFixture: Bool,
        handle: FileHandle
    ) {
        self.url = url
        self.particleCount = particleCount
        self.durationSeconds = durationSeconds
        self.frameByteCount = frameByteCount
        self.frames = frames
        self.isLayeredFixture = isLayeredFixture
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    func frame(at seconds: Double, settings: MLPlaybackViewportSettings) -> PlaybackParticleFrame {
        if settings.interpolationEnabled {
            return interpolatedFrame(at: seconds, settings: settings)
        }
        return nearestFrame(at: seconds, settings: settings)
    }

    private func interpolatedFrame(at seconds: Double, settings: MLPlaybackViewportSettings) -> PlaybackParticleFrame {
        guard frames.count > 1 else {
            return nearestFrame(at: seconds, settings: settings)
        }

        let boundedSeconds = min(max(0, seconds), durationSeconds)
        guard let first = frames.first else {
            return PlaybackParticleFrame(sampleIndex: 0, timeSeconds: boundedSeconds, particles: [])
        }
        if boundedSeconds <= first.timeSeconds {
            return readFrame(first, sampleIndex: 0, timelineSeconds: boundedSeconds, settings: settings)
        }
        if let last = frames.last, boundedSeconds >= last.timeSeconds {
            return readFrame(last, sampleIndex: max(0, frames.count - 1), timelineSeconds: boundedSeconds, settings: settings)
        }

        let upperIndex = upperFrameIndex(for: boundedSeconds)
        let lowerIndex = max(0, upperIndex - 1)
        let upperClampedIndex = min(upperIndex, frames.count - 1)
        let lowerFrame = frames[lowerIndex]
        let upperFrame = frames[upperClampedIndex]
        let denominator = max(0.000001, upperFrame.timeSeconds - lowerFrame.timeSeconds)
        let alpha = Float(min(max((boundedSeconds - lowerFrame.timeSeconds) / denominator, 0), 1))

        guard alpha > 0 else {
            return readFrame(lowerFrame, sampleIndex: lowerIndex, timelineSeconds: boundedSeconds, settings: settings)
        }
        guard alpha < 1 else {
            return readFrame(upperFrame, sampleIndex: upperClampedIndex, timelineSeconds: boundedSeconds, settings: settings)
        }
        guard let lowerParticles = particles(frame: lowerFrame, settings: settings),
              let upperParticles = particles(frame: upperFrame, settings: settings) else {
            return nearestFrame(at: boundedSeconds, settings: settings)
        }

        let count = min(lowerParticles.count, upperParticles.count)
        var particles: [ParticleState] = []
        particles.reserveCapacity(count)
        for index in 0..<count {
            let lowerParticle = lowerParticles[index]
            let upperParticle = upperParticles[index]
            particles.append(
                ParticleState(
                    position: interpolate(lowerParticle.position, upperParticle.position, alpha: alpha),
                    velocity: interpolate(lowerParticle.velocity, upperParticle.velocity, alpha: alpha),
                    impulse: interpolate(lowerParticle.impulse, upperParticle.impulse, alpha: alpha),
                    type: lowerParticle.type,
                    particleID: lowerParticle.particleID,
                    active: lowerParticle.active
                )
            )
        }
        return PlaybackParticleFrame(
            sampleIndex: lowerIndex,
            timeSeconds: boundedSeconds,
            particles: particles
        )
    }

    private func nearestFrame(at seconds: Double, settings: MLPlaybackViewportSettings) -> PlaybackParticleFrame {
        guard let first = frames.first else {
            let boundedSeconds = min(max(0, seconds), durationSeconds)
            return PlaybackParticleFrame(sampleIndex: 0, timeSeconds: boundedSeconds, particles: [])
        }

        let boundedSeconds = min(max(0, seconds), durationSeconds)
        var nearestIndex = 0
        var nearestFrame = first
        var nearestDistance = abs(first.timeSeconds - boundedSeconds)

        for (index, frame) in frames.enumerated().dropFirst() {
            let distance = abs(frame.timeSeconds - boundedSeconds)
            if distance <= nearestDistance {
                nearestIndex = index
                nearestFrame = frame
                nearestDistance = distance
            } else if frame.timeSeconds > boundedSeconds {
                break
            }
        }

        return readFrame(nearestFrame, sampleIndex: nearestIndex, timelineSeconds: boundedSeconds, settings: settings)
    }

    private func readFrame(
        _ frame: MLPlaybackFrameIndex,
        sampleIndex: Int,
        timelineSeconds: Double,
        settings: MLPlaybackViewportSettings
    ) -> PlaybackParticleFrame {
        PlaybackParticleFrame(
            sampleIndex: sampleIndex,
            timeSeconds: timelineSeconds,
            particles: particles(frame: frame, settings: settings) ?? []
        )
    }

    private func particles(
        frame: MLPlaybackFrameIndex,
        settings: MLPlaybackViewportSettings
    ) -> [ParticleState]? {
        let key = MLPlaybackFrameCacheKey(
            step: frame.step,
            surfaceSelectionMode: settings.surfaceSelectionMode,
            normalizationMode: settings.normalizationMode,
            amplitudeScale: settings.amplitudeScale,
            frontLayer: settings.frontLayer,
            middleLayer: settings.middleLayer,
            finalLayer: settings.finalLayer
        )
        if let cached = cachedFrames[key] {
            return cached
        }

        guard let decoded = readParticles(frame: frame, settings: settings) else {
            return nil
        }
        var prepared = decoded
        prepareSurfaceHeights(&prepared, settings: settings)
        cachedFrames[key] = prepared
        cachedFrameOrder.append(key)
        while cachedFrameOrder.count > cacheLimit {
            let evicted = cachedFrameOrder.removeFirst()
            cachedFrames.removeValue(forKey: evicted)
        }
        return prepared
    }

    private func readParticles(
        frame: MLPlaybackFrameIndex,
        settings: MLPlaybackViewportSettings
    ) -> [ParticleState]? {
        do {
            if isLayeredFixture,
               settings.surfaceSelectionMode == .frontMiddleFinal,
               let selected = try readSelectedLayeredParticles(
                frame: frame,
                selections: settings.selectedLayerSurfaces
               ) {
                return selected
            }

            try handle.seek(toOffset: frame.byteOffset)
            let frameData = handle.readData(ofLength: Int(frameByteCount))
            guard UInt64(frameData.count) == frameByteCount else { return nil }
            return try frameData.withUnsafeBytes { rawBuffer in
                var cursor = 0
                _ = try MLPlaybackFixtureLoader.read(UInt32.self, from: rawBuffer, cursor: &cursor)
                _ = try MLPlaybackFixtureLoader.read(Double.self, from: rawBuffer, cursor: &cursor)
                return try MLPlaybackFixtureLoader.decodeParticles(
                    particleCount: particleCount,
                    isLayeredFixture: isLayeredFixture,
                    from: rawBuffer,
                    cursor: &cursor
                )
            }
        } catch {
            RuntimeEventLogger.log("ml_playback frame_read_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private func readSelectedLayeredParticles(
        frame: MLPlaybackFrameIndex,
        selections: [MLPlaybackSurfaceSelection]
    ) throws -> [ParticleState]? {
        let surfaceCount = 15
        guard !selections.isEmpty else { return [] }
        guard particleCount % surfaceCount == 0 else { return nil }
        let surfaceParticleCount = particleCount / surfaceCount
        let surfaceByteCount = surfaceParticleCount * MLPlaybackFixtureLoader.binaryParticleRecordByteCount
        var particles: [ParticleState] = []
        particles.reserveCapacity(surfaceParticleCount * selections.count)

        for surface in selections {
            let layer = min(max(0, surface.layer), 2)
            let slot = min(max(0, surface.slot), 4)
            let groupIndex = layer * 5 + slot
            let byteOffset = frame.byteOffset + UInt64(4 + 8 + groupIndex * surfaceByteCount)
            try handle.seek(toOffset: byteOffset)
            let surfaceData = handle.readData(ofLength: surfaceByteCount)
            guard surfaceData.count == surfaceByteCount else { return nil }
            let decodedSurface = try surfaceData.withUnsafeBytes { rawBuffer in
                var cursor = 0
                return try MLPlaybackFixtureLoader.decodeParticles(
                    particleCount: surfaceParticleCount,
                    isLayeredFixture: true,
                    from: rawBuffer,
                    cursor: &cursor
                )
            }
            particles.append(contentsOf: decodedSurface)
        }
        return particles
    }

    private func prepareSurfaceHeights(
        _ particles: inout [ParticleState],
        settings: MLPlaybackViewportSettings
    ) {
        guard !particles.isEmpty else { return }
        let declaredSurfaceCount = settings.surfaceCount
        let surfaceParticleCount: Int? = {
            if particles.count % declaredSurfaceCount == 0 {
                return particles.count / declaredSurfaceCount
            }
            if particles.count % 15 == 0 {
                return particles.count / 15
            }
            return nil
        }()
        guard let surfaceParticleCount, surfaceParticleCount > 0 else { return }

        let surfaceHeightScale = settings.amplitudeScale
        let surfaceCount = max(1, particles.count / surfaceParticleCount)
        for surfaceIndex in 0..<surfaceCount {
            let surfaceStart = surfaceIndex * surfaceParticleCount
            let surfaceEnd = min(particles.count, surfaceStart + surfaceParticleCount)
            guard surfaceStart < surfaceEnd else { continue }

            var rawMinimum = Float.greatestFiniteMagnitude
            var rawMaximum = -Float.greatestFiniteMagnitude
            for index in surfaceStart..<surfaceEnd {
                let rawActivation = particles[index].velocity.x
                rawMinimum = min(rawMinimum, rawActivation)
                rawMaximum = max(rawMaximum, rawActivation)
            }
            let rawMidpoint = (rawMinimum + rawMaximum) * 0.5
            let rawHalfRange = max(0.000001, (rawMaximum - rawMinimum) * 0.5)

            var mean: Float = 0
            for index in surfaceStart..<surfaceEnd {
                let height: Float
                switch settings.normalizationMode {
                case .global:
                    height = particles[index].position.z
                case .perFrame:
                    height = ((particles[index].velocity.x - rawMidpoint) / rawHalfRange) * surfaceHeightScale
                }
                particles[index].position.z = height
                mean += height
            }
            mean /= Float(max(1, surfaceEnd - surfaceStart))

            var maxCenteredMagnitude: Float = 0.000001
            for index in surfaceStart..<surfaceEnd {
                let centeredHeight = particles[index].position.z - mean
                particles[index].position.z = centeredHeight
                maxCenteredMagnitude = max(maxCenteredMagnitude, abs(centeredHeight))
            }

            let normalizationScale = surfaceHeightScale / maxCenteredMagnitude
            for index in surfaceStart..<surfaceEnd {
                particles[index].position.z *= normalizationScale
            }
        }
    }

    private func upperFrameIndex(for seconds: Double) -> Int {
        var lower = 1
        var upper = frames.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if frames[middle].timeSeconds < seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func interpolate(_ lower: SIMD4<Float>, _ upper: SIMD4<Float>, alpha: Float) -> SIMD3<Float> {
        let lower3 = SIMD3<Float>(lower.x, lower.y, lower.z)
        let upper3 = SIMD3<Float>(upper.x, upper.y, upper.z)
        return lower3 + (upper3 - lower3) * alpha
    }
}

private struct MLPlaybackFrameCacheKey: Hashable {
    let step: Int
    let surfaceSelectionMode: MLPlaybackSurfaceSelectionMode
    let normalizationMode: MLPlaybackNormalizationMode
    let amplitudeScale: Float
    let frontLayer: MLPlaybackLayerSettings
    let middleLayer: MLPlaybackLayerSettings
    let finalLayer: MLPlaybackLayerSettings
}

private struct MLPlaybackFrameIndex {
    let step: Int
    let timeSeconds: Double
    let byteOffset: UInt64
}

private enum MLPlaybackFixtureLoader {
    private static let binaryMagic = [UInt8]("MLPBST1\0".utf8)
    fileprivate static let binaryParticleRecordByteCount = 40

    static func loadFixture() -> MLPlaybackFixture? {
        let url = projectRootURL().appendingPathComponent(MLPlaybackRuntime.fixturePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            RuntimeEventLogger.log("ml_playback fixture_missing path=\(url.path)")
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let headerByteCount = binaryMagic.count + 4 + 4 + 8
            let headerData = handle.readData(ofLength: headerByteCount)
            return try headerData.withUnsafeBytes { rawBuffer in
                var cursor = 0
                let magic = try readBytes(count: binaryMagic.count, from: rawBuffer, cursor: &cursor)
                guard magic == binaryMagic else {
                    throw MLPlaybackFixtureDecodeError.invalidMagic
                }

                let frameCount = Int(try read(UInt32.self, from: rawBuffer, cursor: &cursor))
                let particleCount = Int(try read(UInt32.self, from: rawBuffer, cursor: &cursor))
                guard particleCount <= SimulationParticleLimits.engineCap else {
                    throw MLPlaybackFixtureDecodeError.particleCountExceedsEngineCap(particleCount)
                }
                let durationSeconds = try read(Double.self, from: rawBuffer, cursor: &cursor)
                let frameByteCount = UInt64(4 + 8 + particleCount * binaryParticleRecordByteCount)
                var frames: [MLPlaybackFrameIndex] = []
                frames.reserveCapacity(frameCount)

                var frameOffset = UInt64(headerByteCount)
                for _ in 0..<frameCount {
                    try handle.seek(toOffset: frameOffset)
                    let frameHeaderData = handle.readData(ofLength: 4 + 8)
                    guard frameHeaderData.count == 12 else {
                        throw MLPlaybackFixtureDecodeError.truncatedData
                    }
                    let frameIndex = try frameHeaderData.withUnsafeBytes { frameHeaderBuffer in
                        var frameHeaderCursor = 0
                        return MLPlaybackFrameIndex(
                            step: Int(try read(UInt32.self, from: frameHeaderBuffer, cursor: &frameHeaderCursor)),
                            timeSeconds: try read(Double.self, from: frameHeaderBuffer, cursor: &frameHeaderCursor),
                            byteOffset: frameOffset
                        )
                    }
                    frames.append(frameIndex)
                    frameOffset += frameByteCount
                }

                let runtimeHandle = try FileHandle(forReadingFrom: url)
                return MLPlaybackFixture(
                    url: url,
                    particleCount: particleCount,
                    durationSeconds: durationSeconds,
                    frameByteCount: frameByteCount,
                    frames: frames,
                    isLayeredFixture: url.lastPathComponent.contains("layers15"),
                    handle: runtimeHandle
                )
            }
        } catch {
            RuntimeEventLogger.log("ml_playback fixture_decode_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    fileprivate static func decodeParticles(
        particleCount: Int,
        isLayeredFixture: Bool,
        from rawBuffer: UnsafeRawBufferPointer,
        cursor: inout Int
    ) throws -> [ParticleState] {
        var particles: [ParticleState] = []
        particles.reserveCapacity(particleCount)

        for particleIndex in 0..<particleCount {
            let x = try read(Float.self, from: rawBuffer, cursor: &cursor)
            let y = try read(Float.self, from: rawBuffer, cursor: &cursor)
            let z = try read(Float.self, from: rawBuffer, cursor: &cursor)
            let type = try read(UInt32.self, from: rawBuffer, cursor: &cursor)
            let particleID = try read(UInt32.self, from: rawBuffer, cursor: &cursor)
            let sidecar0 = try read(Float.self, from: rawBuffer, cursor: &cursor)
            let sidecar1 = try read(Float.self, from: rawBuffer, cursor: &cursor)
            let sidecar2 = try read(Float.self, from: rawBuffer, cursor: &cursor)
            let sidecar3 = try read(Float.self, from: rawBuffer, cursor: &cursor)
            let sidecar4 = try read(Float.self, from: rawBuffer, cursor: &cursor)
            let stableID = particleID == UInt32.max ? UInt32(particleIndex) : particleID

            particles.append(
                ParticleState(
                    position: SIMD3<Float>(x, y, z),
                    velocity: SIMD3<Float>(sidecar0, sidecar1, sidecar2),
                    impulse: SIMD3<Float>(sidecar3, sidecar4, isLayeredFixture ? Float(type) : 0),
                    type: type,
                    particleID: stableID,
                    active: 1
                )
            )
        }
        return particles
    }

    fileprivate static func read<T>(_ type: T.Type, from rawBuffer: UnsafeRawBufferPointer, cursor: inout Int) throws -> T {
        guard cursor + MemoryLayout<T>.size <= rawBuffer.count else {
            throw MLPlaybackFixtureDecodeError.truncatedData
        }
        let value = rawBuffer.loadUnaligned(fromByteOffset: cursor, as: T.self)
        cursor += MemoryLayout<T>.size
        return value
    }

    private static func readBytes(count: Int, from rawBuffer: UnsafeRawBufferPointer, cursor: inout Int) throws -> [UInt8] {
        guard cursor + count <= rawBuffer.count else {
            throw MLPlaybackFixtureDecodeError.truncatedData
        }
        let bytes = Array(rawBuffer[cursor..<(cursor + count)])
        cursor += count
        return bytes
    }

    private static func projectRootURL() -> URL {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

        while true {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            }
            candidate = parent
        }
    }
}

private enum MLPlaybackFixtureDecodeError: LocalizedError {
    case invalidMagic
    case particleCountExceedsEngineCap(Int)
    case truncatedData

    var errorDescription: String? {
        switch self {
        case .invalidMagic:
            return "Invalid ML playback fixture magic."
        case .particleCountExceedsEngineCap(let particleCount):
            return "ML playback fixture particle count \(particleCount) exceeds the engine cap."
        case .truncatedData:
            return "ML playback fixture ended before all records were read."
        }
    }
}
