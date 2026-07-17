import Foundation
import simd

final class MLPlaybackRuntime: ParticlePlaybackRuntime {
    static let fixturePath = "Sources/lab/data/derived/ml_playback_neuron_sweeps_v3/e08_run001_layers15.mlpb"

    private let fixture: MLPlaybackFixture

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

    func frame(at seconds: Double) -> PlaybackParticleFrame {
        fixture.interpolatedFrame(at: seconds)
    }
}

private struct MLPlaybackFixture {
    let url: URL
    let particleCount: Int
    let durationSeconds: Double
    let frameByteCount: UInt64
    let frames: [MLPlaybackFrameIndex]
    let isLayeredFixture: Bool

    func interpolatedFrame(at seconds: Double) -> PlaybackParticleFrame {
        guard frames.count > 1 else {
            return nearestFrame(at: seconds)
        }

        let boundedSeconds = min(max(0, seconds), durationSeconds)
        guard let first = frames.first else {
            return PlaybackParticleFrame(sampleIndex: 0, timeSeconds: boundedSeconds, particles: [])
        }
        if boundedSeconds <= first.timeSeconds {
            return readFrame(first, sampleIndex: 0, timelineSeconds: boundedSeconds)
        }
        if let last = frames.last, boundedSeconds >= last.timeSeconds {
            return readFrame(last, sampleIndex: max(0, frames.count - 1), timelineSeconds: boundedSeconds)
        }

        var upperIndex = 1
        while upperIndex < frames.count && frames[upperIndex].timeSeconds < boundedSeconds {
            upperIndex += 1
        }

        let lowerIndex = max(0, upperIndex - 1)
        let upperClampedIndex = min(upperIndex, frames.count - 1)
        let lowerFrame = frames[lowerIndex]
        let upperFrame = frames[upperClampedIndex]
        let denominator = max(0.000001, upperFrame.timeSeconds - lowerFrame.timeSeconds)
        let alpha = Float(min(max((boundedSeconds - lowerFrame.timeSeconds) / denominator, 0), 1))

        guard alpha > 0 else {
            return readFrame(lowerFrame, sampleIndex: lowerIndex, timelineSeconds: boundedSeconds)
        }
        guard alpha < 1 else {
            return readFrame(upperFrame, sampleIndex: upperClampedIndex, timelineSeconds: boundedSeconds)
        }
        guard let lowerParticles = readParticles(frame: lowerFrame),
              let upperParticles = readParticles(frame: upperFrame) else {
            return nearestFrame(at: boundedSeconds)
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

    private func nearestFrame(at seconds: Double) -> PlaybackParticleFrame {
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

        return readFrame(nearestFrame, sampleIndex: nearestIndex, timelineSeconds: boundedSeconds)
    }

    private func readFrame(
        _ frame: MLPlaybackFrameIndex,
        sampleIndex: Int,
        timelineSeconds: Double
    ) -> PlaybackParticleFrame {
        PlaybackParticleFrame(
            sampleIndex: sampleIndex,
            timeSeconds: timelineSeconds,
            particles: readParticles(frame: frame) ?? []
        )
    }

    private func readParticles(frame: MLPlaybackFrameIndex) -> [ParticleState]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
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

    private func interpolate(_ lower: SIMD4<Float>, _ upper: SIMD4<Float>, alpha: Float) -> SIMD3<Float> {
        let lower3 = SIMD3<Float>(lower.x, lower.y, lower.z)
        let upper3 = SIMD3<Float>(upper.x, upper.y, upper.z)
        return lower3 + (upper3 - lower3) * alpha
    }
}

private struct MLPlaybackFrameIndex {
    let step: Int
    let timeSeconds: Double
    let byteOffset: UInt64
}

private enum MLPlaybackFixtureLoader {
    private static let binaryMagic = [UInt8]("MLPBST1\0".utf8)
    private static let binaryParticleRecordByteCount = 40

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

                return MLPlaybackFixture(
                    url: url,
                    particleCount: particleCount,
                    durationSeconds: durationSeconds,
                    frameByteCount: frameByteCount,
                    frames: frames,
                    isLayeredFixture: url.lastPathComponent.contains("layers15")
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
