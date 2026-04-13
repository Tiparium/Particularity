import Foundation
import simd

struct PlaybackTimelineSnapshot: Equatable {
    static let placeholder = PlaybackTimelineSnapshot(
        currentSeconds: 0,
        durationSeconds: 52,
        isLooping: true,
        playbackTimeScale: 1.0,
        interpolationEnabled: false
    )

    var currentSeconds: Double
    var durationSeconds: Double
    var isLooping: Bool
    var playbackTimeScale: Double
    var interpolationEnabled: Bool
}

struct MLPlaybackPrototypeLoadedFrame {
    let step: Int
    let timeSeconds: Double
    let particles: [ParticleState]
}

struct MLPlaybackSurfaceSelection: Equatable {
    let layer: Int
    let slot: Int
}

struct MLPlaybackPrototypeFixture {
    let schema: String
    let particleCount: Int
    let durationSeconds: Double
    private let storage: MLPlaybackPrototypeStorage

    init(
        schema: String,
        particleCount: Int,
        durationSeconds: Double,
        frames: [MLPlaybackPrototypeLoadedFrame]
    ) {
        self.schema = schema
        self.particleCount = particleCount
        self.durationSeconds = durationSeconds
        self.storage = .memory(frames)
    }

    fileprivate init(
        schema: String,
        particleCount: Int,
        durationSeconds: Double,
        binarySource: MLPlaybackPrototypeBinarySource
    ) {
        self.schema = schema
        self.particleCount = particleCount
        self.durationSeconds = durationSeconds
        self.storage = .binary(binarySource)
    }

    func particles(at seconds: Double) -> (step: Int, particles: [ParticleState]) {
        particles(at: seconds, selection: nil)
    }

    func particles(
        at seconds: Double,
        selection: [MLPlaybackSurfaceSelection]?
    ) -> (step: Int, particles: [ParticleState]) {
        switch storage {
        case .memory(let frames):
            let frame = memoryParticles(at: seconds, frames: frames)
            return (frame.step, selectedParticles(frame.particles, selection: selection))
        case .binary(let binarySource):
            return binarySource.particles(
                at: seconds,
                durationSeconds: durationSeconds,
                selection: selection
            )
        }
    }

    func interpolatedParticles(at seconds: Double) -> (step: Int, particles: [ParticleState]) {
        interpolatedParticles(at: seconds, selection: nil)
    }

    func interpolatedParticles(
        at seconds: Double,
        selection: [MLPlaybackSurfaceSelection]?
    ) -> (step: Int, particles: [ParticleState]) {
        switch storage {
        case .memory(let frames):
            let frame = memoryInterpolatedParticles(at: seconds, frames: frames)
            return (frame.step, selectedParticles(frame.particles, selection: selection))
        case .binary(let binarySource):
            return binarySource.interpolatedParticles(
                at: seconds,
                durationSeconds: durationSeconds,
                selection: selection
            )
        }
    }

    private func memoryParticles(
        at seconds: Double,
        frames: [MLPlaybackPrototypeLoadedFrame]
    ) -> (step: Int, particles: [ParticleState]) {
        guard let firstFrame = frames.first else {
            return (0, [])
        }

        let boundedSeconds = min(max(0, seconds), durationSeconds)
        var nearestFrame = firstFrame
        var nearestDistance = abs(firstFrame.timeSeconds - boundedSeconds)

        for frame in frames.dropFirst() {
            let distance = abs(frame.timeSeconds - boundedSeconds)
            if distance <= nearestDistance {
                nearestFrame = frame
                nearestDistance = distance
            } else if frame.timeSeconds > boundedSeconds {
                break
            }
        }

        return (nearestFrame.step, nearestFrame.particles)
    }

    private func memoryInterpolatedParticles(
        at seconds: Double,
        frames: [MLPlaybackPrototypeLoadedFrame]
    ) -> (step: Int, particles: [ParticleState]) {
        guard let firstFrame = frames.first else {
            return (0, [])
        }
        guard frames.count > 1 else {
            return (firstFrame.step, firstFrame.particles)
        }

        let boundedSeconds = min(max(0, seconds), durationSeconds)
        if boundedSeconds <= firstFrame.timeSeconds {
            return (firstFrame.step, firstFrame.particles)
        }
        if let lastFrame = frames.last, boundedSeconds >= lastFrame.timeSeconds {
            return (lastFrame.step, lastFrame.particles)
        }

        var upperIndex = 1
        while upperIndex < frames.count && frames[upperIndex].timeSeconds < boundedSeconds {
            upperIndex += 1
        }
        let lowerIndex = max(0, upperIndex - 1)
        let lower = frames[lowerIndex]
        let upper = frames[min(upperIndex, frames.count - 1)]
        let denominator = max(0.000001, upper.timeSeconds - lower.timeSeconds)
        let alpha = Float(min(max((boundedSeconds - lower.timeSeconds) / denominator, 0), 1))
        if alpha <= 0 {
            return (lower.step, lower.particles)
        }
        if alpha >= 1 {
            return (upper.step, upper.particles)
        }

        let count = min(lower.particles.count, upper.particles.count)
        var particles: [ParticleState] = []
        particles.reserveCapacity(count)
        for index in 0..<count {
            let lowerParticle = lower.particles[index]
            let upperParticle = upper.particles[index]
            let lowerPosition = SIMD3<Float>(lowerParticle.position.x, lowerParticle.position.y, lowerParticle.position.z)
            let upperPosition = SIMD3<Float>(upperParticle.position.x, upperParticle.position.y, upperParticle.position.z)
            let lowerVelocity = SIMD3<Float>(lowerParticle.velocity.x, lowerParticle.velocity.y, lowerParticle.velocity.z)
            let upperVelocity = SIMD3<Float>(upperParticle.velocity.x, upperParticle.velocity.y, upperParticle.velocity.z)
            let lowerImpulse = SIMD3<Float>(lowerParticle.impulse.x, lowerParticle.impulse.y, lowerParticle.impulse.z)
            let upperImpulse = SIMD3<Float>(upperParticle.impulse.x, upperParticle.impulse.y, upperParticle.impulse.z)
            particles.append(
                ParticleState(
                    position: lowerPosition + (upperPosition - lowerPosition) * alpha,
                    velocity: lowerVelocity + (upperVelocity - lowerVelocity) * alpha,
                    impulse: lowerImpulse + (upperImpulse - lowerImpulse) * alpha,
                    type: lowerParticle.type,
                    particleID: lowerParticle.particleID,
                    active: lowerParticle.active
                )
            )
        }

        return (lower.step, particles)
    }

    private func selectedParticles(
        _ particles: [ParticleState],
        selection: [MLPlaybackSurfaceSelection]?
    ) -> [ParticleState] {
        guard let selection else { return particles }
        guard !selection.isEmpty else { return [] }
        return particles.filter { particle in
            let particleLayer = Int(particle.impulse.y.rounded())
            let particleSlot = Int(particle.impulse.z.rounded())
            return selection.contains {
                $0.layer == particleLayer && $0.slot == particleSlot
            }
        }
    }
}

private enum MLPlaybackPrototypeStorage {
    case memory([MLPlaybackPrototypeLoadedFrame])
    case binary(MLPlaybackPrototypeBinarySource)
}

private struct MLPlaybackPrototypeBinaryFrameIndex {
    let step: Int
    let timeSeconds: Double
    let byteOffset: UInt64
}

private struct MLPlaybackPrototypeBinarySource {
    let url: URL
    let particleCount: Int
    let frameByteCount: UInt64
    let frames: [MLPlaybackPrototypeBinaryFrameIndex]
    let isLayeredFixture: Bool

    func particles(
        at seconds: Double,
        durationSeconds: Double,
        selection: [MLPlaybackSurfaceSelection]?
    ) -> (step: Int, particles: [ParticleState]) {
        if let selection, selection.isEmpty {
            return (nearestFrame(at: seconds, durationSeconds: durationSeconds)?.step ?? 0, [])
        }
        guard let frame = nearestFrame(at: seconds, durationSeconds: durationSeconds),
              let particles = readParticles(frame: frame, selection: selection) else {
            return (0, [])
        }
        return (frame.step, particles)
    }

    func interpolatedParticles(
        at seconds: Double,
        durationSeconds: Double,
        selection: [MLPlaybackSurfaceSelection]?
    ) -> (step: Int, particles: [ParticleState]) {
        if let selection, selection.isEmpty {
            return (nearestFrame(at: seconds, durationSeconds: durationSeconds)?.step ?? 0, [])
        }
        guard frames.count > 1 else {
            return particles(at: seconds, durationSeconds: durationSeconds, selection: selection)
        }

        let boundedSeconds = min(max(0, seconds), durationSeconds)
        if let first = frames.first, boundedSeconds <= first.timeSeconds {
            return particles(at: boundedSeconds, durationSeconds: durationSeconds, selection: selection)
        }
        if let last = frames.last, boundedSeconds >= last.timeSeconds {
            return particles(at: boundedSeconds, durationSeconds: durationSeconds, selection: selection)
        }

        var upperIndex = 1
        while upperIndex < frames.count && frames[upperIndex].timeSeconds < boundedSeconds {
            upperIndex += 1
        }
        let lowerIndex = max(0, upperIndex - 1)
        let lowerFrame = frames[lowerIndex]
        let upperFrame = frames[min(upperIndex, frames.count - 1)]
        let denominator = max(0.000001, upperFrame.timeSeconds - lowerFrame.timeSeconds)
        let alpha = Float(min(max((boundedSeconds - lowerFrame.timeSeconds) / denominator, 0), 1))

        if alpha <= 0 {
            return particles(at: lowerFrame.timeSeconds, durationSeconds: durationSeconds, selection: selection)
        }
        if alpha >= 1 {
            return particles(at: upperFrame.timeSeconds, durationSeconds: durationSeconds, selection: selection)
        }

        guard let lowerParticles = readParticles(frame: lowerFrame, selection: selection),
              let upperParticles = readParticles(frame: upperFrame, selection: selection) else {
            return particles(at: boundedSeconds, durationSeconds: durationSeconds, selection: selection)
        }

        let count = min(lowerParticles.count, upperParticles.count)
        var particles: [ParticleState] = []
        particles.reserveCapacity(count)
        for index in 0..<count {
            let lowerParticle = lowerParticles[index]
            let upperParticle = upperParticles[index]
            let lowerPosition = SIMD3<Float>(lowerParticle.position.x, lowerParticle.position.y, lowerParticle.position.z)
            let upperPosition = SIMD3<Float>(upperParticle.position.x, upperParticle.position.y, upperParticle.position.z)
            let lowerVelocity = SIMD3<Float>(lowerParticle.velocity.x, lowerParticle.velocity.y, lowerParticle.velocity.z)
            let upperVelocity = SIMD3<Float>(upperParticle.velocity.x, upperParticle.velocity.y, upperParticle.velocity.z)
            let lowerImpulse = SIMD3<Float>(lowerParticle.impulse.x, lowerParticle.impulse.y, lowerParticle.impulse.z)
            let upperImpulse = SIMD3<Float>(upperParticle.impulse.x, upperParticle.impulse.y, upperParticle.impulse.z)
            particles.append(
                ParticleState(
                    position: lowerPosition + (upperPosition - lowerPosition) * alpha,
                    velocity: lowerVelocity + (upperVelocity - lowerVelocity) * alpha,
                    impulse: lowerImpulse + (upperImpulse - lowerImpulse) * alpha,
                    type: lowerParticle.type,
                    particleID: lowerParticle.particleID,
                    active: lowerParticle.active
                )
            )
        }
        return (lowerFrame.step, particles)
    }

    private func nearestFrame(
        at seconds: Double,
        durationSeconds: Double
    ) -> MLPlaybackPrototypeBinaryFrameIndex? {
        guard let firstFrame = frames.first else { return nil }
        let boundedSeconds = min(max(0, seconds), durationSeconds)
        var nearestFrame = firstFrame
        var nearestDistance = abs(firstFrame.timeSeconds - boundedSeconds)

        for frame in frames.dropFirst() {
            let distance = abs(frame.timeSeconds - boundedSeconds)
            if distance <= nearestDistance {
                nearestFrame = frame
                nearestDistance = distance
            } else if frame.timeSeconds > boundedSeconds {
                break
            }
        }
        return nearestFrame
    }

    private func readParticles(
        frame: MLPlaybackPrototypeBinaryFrameIndex,
        selection: [MLPlaybackSurfaceSelection]?
    ) -> [ParticleState]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            if isLayeredFixture, let selection, !selection.isEmpty {
                return try readSelectedLayeredParticles(
                    frame: frame,
                    selection: selection,
                    handle: handle
                )
            }

            try handle.seek(toOffset: frame.byteOffset)
            let frameData = handle.readData(ofLength: Int(frameByteCount))
            guard UInt64(frameData.count) == frameByteCount else { return nil }
            return try frameData.withUnsafeBytes { rawBuffer in
                var cursor = 0
                _ = try MLPlaybackPrototypeFixtureLoader.read(UInt32.self, from: rawBuffer, cursor: &cursor)
                _ = try MLPlaybackPrototypeFixtureLoader.read(Double.self, from: rawBuffer, cursor: &cursor)
                return try MLPlaybackPrototypeFixtureLoader.decodeParticles(
                    particleCount: particleCount,
                    isLayeredFixture: isLayeredFixture,
                    from: rawBuffer,
                    cursor: &cursor
                )
            }
        } catch {
            RuntimeEventLogger.log("ml_playback binary_frame_read_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private func readSelectedLayeredParticles(
        frame: MLPlaybackPrototypeBinaryFrameIndex,
        selection: [MLPlaybackSurfaceSelection],
        handle: FileHandle
    ) throws -> [ParticleState]? {
        let surfaceCount = 15
        guard particleCount % surfaceCount == 0 else { return nil }
        let surfaceParticleCount = particleCount / surfaceCount
        let surfaceByteCount = surfaceParticleCount * MLPlaybackPrototypeFixtureLoader.binaryParticleRecordByteCount
        var particles: [ParticleState] = []
        particles.reserveCapacity(surfaceParticleCount * selection.count)

        for surface in selection {
            let layer = min(max(0, surface.layer), 2)
            let slot = min(max(0, surface.slot), 4)
            let groupIndex = layer * 5 + slot
            let byteOffset = frame.byteOffset + UInt64(4 + 8 + groupIndex * surfaceByteCount)
            try handle.seek(toOffset: byteOffset)
            let surfaceData = handle.readData(ofLength: surfaceByteCount)
            guard surfaceData.count == surfaceByteCount else { return nil }
            let decodedSurface = try surfaceData.withUnsafeBytes { rawBuffer in
                var cursor = 0
                return try MLPlaybackPrototypeFixtureLoader.decodeParticles(
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
}

private struct MLPlaybackPrototypeJSONParticle: Decodable {
    let id: Int
    let position: SIMD3<Float>
    let type: UInt32
    let sidecar: MLPlaybackPrototypeJSONSidecar

    private enum CodingKeys: String, CodingKey {
        case id
        case position
        case type
        case sidecar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        let decodedPosition = try container.decode([Float].self, forKey: .position)
        position = SIMD3<Float>(
            decodedPosition.indices.contains(0) ? decodedPosition[0] : 0,
            decodedPosition.indices.contains(1) ? decodedPosition[1] : 0,
            decodedPosition.indices.contains(2) ? decodedPosition[2] : 0
        )
        type = try UInt32(container.decode(Int.self, forKey: .type))
        sidecar = try container.decode(MLPlaybackPrototypeJSONSidecar.self, forKey: .sidecar)
    }
}

private struct MLPlaybackPrototypeJSONSidecar: Decodable {
    let confidence: Float
    let margin: Float
    let correctness: Int
    let prediction: Int
    let target: Int
}

private struct MLPlaybackPrototypeJSONFrame: Decodable {
    let step: Int
    let timeSeconds: Double
    let particles: [MLPlaybackPrototypeJSONParticle]
}

private struct MLPlaybackPrototypeJSONFixture: Decodable {
    let schema: String
    let particleCount: Int
    let durationSeconds: Double
    let frames: [MLPlaybackPrototypeJSONFrame]
}

enum MLPlaybackPrototypeFixtureLoader {
    static let binaryFixturePath = "Sources/lab/data/derived/ml_playback_neuron_sweeps_v3/e08_run001_layers15.mlpb"
    static let previousLayersFixturePath = "Sources/lab/data/derived/ml_playback_neuron_sweeps_v2/e08_run001_layer2_neuron185.mlpb"
    static let previousNeuronFixturePath = "Sources/lab/data/derived/ml_playback_neuron_sweeps_v1/neuron_surface_layer2_neuron292.mlpb"
    static let legacyBinaryFixturePath = "Sources/lab/data/derived/ml_playback_stress_v1/member_001_embedding_probe_20k.mlpb"
    static let jsonFallbackFixturePath = "Sources/lab/data/derived/ml_playback_v0/member_001_probe_playback.json"

    private static let binaryMagic = [UInt8]("MLPBST1\0".utf8)
    fileprivate static let binaryParticleRecordByteCount = 40

    static func loadFixture() -> MLPlaybackPrototypeFixture? {
        if let binaryFixture = loadBinaryFixture() {
            return binaryFixture
        }
        return loadJSONFallbackFixture()
    }

    private static func loadBinaryFixture() -> MLPlaybackPrototypeFixture? {
        let primaryURL = projectRootURL().appendingPathComponent(binaryFixturePath, isDirectory: false)
        let previousLayersURL = projectRootURL().appendingPathComponent(previousLayersFixturePath, isDirectory: false)
        let previousNeuronURL = projectRootURL().appendingPathComponent(previousNeuronFixturePath, isDirectory: false)
        let legacyURL = projectRootURL().appendingPathComponent(legacyBinaryFixturePath, isDirectory: false)
        let url: URL
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            url = primaryURL
        } else if FileManager.default.fileExists(atPath: previousLayersURL.path) {
            url = previousLayersURL
        } else if FileManager.default.fileExists(atPath: previousNeuronURL.path) {
            url = previousNeuronURL
        } else if FileManager.default.fileExists(atPath: legacyURL.path) {
            url = legacyURL
        } else {
            RuntimeEventLogger.log("ml_playback binary_fixture_missing primary=\(primaryURL.path) previous_layers=\(previousLayersURL.path) previous=\(previousNeuronURL.path) legacy=\(legacyURL.path)")
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let headerData = handle.readData(ofLength: binaryMagic.count + 4 + 4 + 8)
            return try headerData.withUnsafeBytes { rawBuffer in
                var headerCursor = 0
                let magic = try readBytes(count: binaryMagic.count, from: rawBuffer, cursor: &headerCursor)
                guard magic == binaryMagic else {
                    throw FixtureDecodeError.invalidMagic
                }

                let frameCount = Int(try read(UInt32.self, from: rawBuffer, cursor: &headerCursor))
                let particleCount = Int(try read(UInt32.self, from: rawBuffer, cursor: &headerCursor))
                guard particleCount <= SimulationParticleLimits.engineCap else {
                    throw FixtureDecodeError.particleCountExceedsEngineCap(particleCount)
                }
                let durationSeconds = try read(Double.self, from: rawBuffer, cursor: &headerCursor)
                let frameByteCount = UInt64(4 + 8 + particleCount * binaryParticleRecordByteCount)
                var frames: [MLPlaybackPrototypeBinaryFrameIndex] = []
                frames.reserveCapacity(frameCount)

                var frameOffset = UInt64(headerData.count)
                for _ in 0..<frameCount {
                    try handle.seek(toOffset: frameOffset)
                    let frameHeaderData = handle.readData(ofLength: 4 + 8)
                    guard frameHeaderData.count == 12 else {
                        throw FixtureDecodeError.truncatedData
                    }
                    let frameHeader = try frameHeaderData.withUnsafeBytes { frameHeaderBuffer in
                        var frameHeaderCursor = 0
                        let step = Int(try read(UInt32.self, from: frameHeaderBuffer, cursor: &frameHeaderCursor))
                        let timeSeconds = try read(Double.self, from: frameHeaderBuffer, cursor: &frameHeaderCursor)
                        return MLPlaybackPrototypeBinaryFrameIndex(
                            step: step,
                            timeSeconds: timeSeconds,
                            byteOffset: frameOffset
                        )
                    }
                    frames.append(frameHeader)
                    frameOffset += frameByteCount
                }

                let schema = url.lastPathComponent.contains("layers15")
                    ? "ml_playback_neuron_sweeps_v3"
                    : (url.lastPathComponent.contains("neuron_surface")
                    ? "ml_playback_neuron_sweeps_v1"
                    : (url.lastPathComponent.contains("run001_layer")
                        ? "ml_playback_neuron_sweeps_v2"
                        : "ml_playback_stress_v1"))
                return MLPlaybackPrototypeFixture(
                    schema: schema,
                    particleCount: particleCount,
                    durationSeconds: durationSeconds,
                    binarySource: MLPlaybackPrototypeBinarySource(
                        url: url,
                        particleCount: particleCount,
                        frameByteCount: frameByteCount,
                        frames: frames,
                        isLayeredFixture: url.lastPathComponent.contains("layers15")
                    )
                )
            }
        } catch {
            RuntimeEventLogger.log("ml_playback binary_fixture_decode_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func loadJSONFallbackFixture() -> MLPlaybackPrototypeFixture? {
        let url = projectRootURL().appendingPathComponent(jsonFallbackFixturePath, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            RuntimeEventLogger.log("ml_playback json_fixture_missing path=\(url.path)")
            return nil
        }

        do {
            let decoded = try JSONDecoder().decode(MLPlaybackPrototypeJSONFixture.self, from: data)
            let frames = decoded.frames.map { frame in
                MLPlaybackPrototypeLoadedFrame(
                    step: frame.step,
                    timeSeconds: frame.timeSeconds,
                    particles: frame.particles.map { particle in
                        ParticleState(
                            position: particle.position,
                            velocity: SIMD3<Float>(
                                particle.sidecar.confidence,
                                particle.sidecar.margin,
                                Float(particle.sidecar.correctness)
                            ),
                            impulse: SIMD3<Float>(
                                Float(particle.sidecar.prediction),
                                1,
                                0
                            ),
                            type: particle.type,
                            particleID: UInt32(particle.id),
                            active: 1
                        )
                    }
                )
            }
            return MLPlaybackPrototypeFixture(
                schema: decoded.schema,
                particleCount: decoded.particleCount,
                durationSeconds: decoded.durationSeconds,
                frames: frames
            )
        } catch {
            RuntimeEventLogger.log("ml_playback json_fixture_decode_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func projectRootURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
                    impulse: SIMD3<Float>(
                        sidecar3,
                        sidecar4,
                        isLayeredFixture ? Float(type) : 0
                    ),
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
            throw FixtureDecodeError.truncatedData
        }
        let value = rawBuffer.loadUnaligned(fromByteOffset: cursor, as: T.self)
        cursor += MemoryLayout<T>.size
        return value
    }

    fileprivate static func readBytes(count: Int, from rawBuffer: UnsafeRawBufferPointer, cursor: inout Int) throws -> [UInt8] {
        guard cursor + count <= rawBuffer.count else {
            throw FixtureDecodeError.truncatedData
        }
        let bytes = Array(rawBuffer[cursor..<(cursor + count)])
        cursor += count
        return bytes
    }

    private enum FixtureDecodeError: LocalizedError {
        case invalidMagic
        case particleCountExceedsEngineCap(Int)
        case truncatedData

        var errorDescription: String? {
            switch self {
            case .invalidMagic:
                return "Invalid ML playback binary fixture magic."
            case .particleCountExceedsEngineCap(let particleCount):
                return "ML playback binary fixture particle count \(particleCount) exceeds the hard engine cap of \(SimulationParticleLimits.engineCap)."
            case .truncatedData:
                return "ML playback binary fixture ended before all records were read."
            }
        }
    }
}
