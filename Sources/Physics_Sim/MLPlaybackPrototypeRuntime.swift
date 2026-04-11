import Foundation
import simd

struct PlaybackTimelineSnapshot: Equatable {
    static let placeholder = PlaybackTimelineSnapshot(
        currentSeconds: 0,
        durationSeconds: 52,
        isLooping: true
    )

    var currentSeconds: Double
    var durationSeconds: Double
    var isLooping: Bool
}

struct MLPlaybackPrototypeLoadedFrame {
    let step: Int
    let timeSeconds: Double
    let particles: [ParticleState]
}

struct MLPlaybackPrototypeFixture {
    let schema: String
    let particleCount: Int
    let durationSeconds: Double
    let frames: [MLPlaybackPrototypeLoadedFrame]

    func particles(at seconds: Double) -> (step: Int, particles: [ParticleState]) {
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
    static let binaryFixturePath = "Sources/lab/data/derived/ml_playback_stress_v1/member_001_embedding_probe_20k.mlpb"
    static let jsonFallbackFixturePath = "Sources/lab/data/derived/ml_playback_v0/member_001_probe_playback.json"

    private static let binaryMagic = [UInt8]("MLPBST1\0".utf8)

    static func loadFixture() -> MLPlaybackPrototypeFixture? {
        if let binaryFixture = loadBinaryFixture() {
            return binaryFixture
        }
        return loadJSONFallbackFixture()
    }

    private static func loadBinaryFixture() -> MLPlaybackPrototypeFixture? {
        let url = projectRootURL().appendingPathComponent(binaryFixturePath, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            RuntimeEventLogger.log("ml_playback binary_fixture_missing path=\(url.path)")
            return nil
        }

        do {
            return try data.withUnsafeBytes { rawBuffer in
                var cursor = 0
                let magic = try readBytes(count: binaryMagic.count, from: rawBuffer, cursor: &cursor)
                guard magic == binaryMagic else {
                    throw FixtureDecodeError.invalidMagic
                }

                let frameCount = Int(try read(UInt32.self, from: rawBuffer, cursor: &cursor))
                let particleCount = Int(try read(UInt32.self, from: rawBuffer, cursor: &cursor))
                guard particleCount <= SimulationParticleLimits.engineCap else {
                    throw FixtureDecodeError.particleCountExceedsEngineCap(particleCount)
                }
                let durationSeconds = try read(Double.self, from: rawBuffer, cursor: &cursor)
                var frames: [MLPlaybackPrototypeLoadedFrame] = []
                frames.reserveCapacity(frameCount)

                for _ in 0..<frameCount {
                    let step = Int(try read(UInt32.self, from: rawBuffer, cursor: &cursor))
                    let timeSeconds = try read(Double.self, from: rawBuffer, cursor: &cursor)
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
                                impulse: SIMD3<Float>(sidecar3, sidecar4, 0),
                                type: type,
                                particleID: stableID,
                                active: 1
                            )
                        )
                    }

                    frames.append(
                        MLPlaybackPrototypeLoadedFrame(
                            step: step,
                            timeSeconds: timeSeconds,
                            particles: particles
                        )
                    )
                }

                return MLPlaybackPrototypeFixture(
                    schema: "ml_playback_stress_v1",
                    particleCount: particleCount,
                    durationSeconds: durationSeconds,
                    frames: frames
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
                                Float(particle.sidecar.target),
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

    private static func read<T>(_ type: T.Type, from rawBuffer: UnsafeRawBufferPointer, cursor: inout Int) throws -> T {
        guard cursor + MemoryLayout<T>.size <= rawBuffer.count else {
            throw FixtureDecodeError.truncatedData
        }
        let value = rawBuffer.loadUnaligned(fromByteOffset: cursor, as: T.self)
        cursor += MemoryLayout<T>.size
        return value
    }

    private static func readBytes(count: Int, from rawBuffer: UnsafeRawBufferPointer, cursor: inout Int) throws -> [UInt8] {
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
