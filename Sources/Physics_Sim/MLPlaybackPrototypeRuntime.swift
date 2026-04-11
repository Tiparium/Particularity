import Foundation
import simd

struct MLPlaybackPrototypeParticle: Decodable {
    let id: Int
    let equation: String
    let split: String
    let position: SIMD3<Float>
    let type: UInt32
    let sidecar: MLPlaybackPrototypeSidecar

    private enum CodingKeys: String, CodingKey {
        case id
        case equation
        case split
        case position
        case type
        case sidecar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        equation = try container.decode(String.self, forKey: .equation)
        split = try container.decode(String.self, forKey: .split)
        let decodedPosition = try container.decode([Float].self, forKey: .position)
        position = SIMD3<Float>(
            decodedPosition.indices.contains(0) ? decodedPosition[0] : 0,
            decodedPosition.indices.contains(1) ? decodedPosition[1] : 0,
            decodedPosition.indices.contains(2) ? decodedPosition[2] : 0
        )
        type = try UInt32(container.decode(Int.self, forKey: .type))
        sidecar = try container.decode(MLPlaybackPrototypeSidecar.self, forKey: .sidecar)
    }
}

struct MLPlaybackPrototypeSidecar: Decodable {
    let confidence: Float
    let margin: Float
    let correctness: Int
    let prediction: Int
    let target: Int
}

struct MLPlaybackPrototypeFrame: Decodable {
    let step: Int
    let timeSeconds: Double
    let particles: [MLPlaybackPrototypeParticle]
}

struct MLPlaybackPrototypeFixture: Decodable {
    let schema: String
    let particleCount: Int
    let durationSeconds: Double
    let frames: [MLPlaybackPrototypeFrame]

    func particles(at seconds: Double) -> (step: Int, particles: [ParticleState]) {
        guard let firstFrame = frames.first else {
            return (0, [])
        }

        let boundedSeconds = min(max(0, seconds), durationSeconds)
        guard frames.count > 1 else {
            return (firstFrame.step, particleStates(from: firstFrame.particles))
        }

        var lowerFrame = firstFrame
        var upperFrame = frames[1]

        for frameIndex in 1..<frames.count {
            upperFrame = frames[frameIndex]
            if upperFrame.timeSeconds >= boundedSeconds {
                break
            }
            lowerFrame = upperFrame
        }

        let span = max(0.000_001, upperFrame.timeSeconds - lowerFrame.timeSeconds)
        let mix = Float((boundedSeconds - lowerFrame.timeSeconds) / span)
        let interpolatedParticles = zip(lowerFrame.particles, upperFrame.particles).map { lower, upper in
            let position = lower.position + (upper.position - lower.position) * mix
            let sidecar = mix < 0.5 ? lower.sidecar : upper.sidecar
            let type = mix < 0.5 ? lower.type : upper.type
            return ParticleState(
                position: position,
                velocity: SIMD3<Float>(sidecar.confidence, sidecar.margin, Float(sidecar.correctness)),
                impulse: SIMD3<Float>(Float(sidecar.prediction), Float(sidecar.target), 0),
                type: type,
                particleID: UInt32(lower.id),
                active: 1
            )
        }

        return (mix < 0.5 ? lowerFrame.step : upperFrame.step, interpolatedParticles)
    }

    private func particleStates(from particles: [MLPlaybackPrototypeParticle]) -> [ParticleState] {
        particles.map { particle in
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
    }
}

enum MLPlaybackPrototypeFixtureLoader {
    static let fixturePath = "Sources/lab/data/derived/ml_playback_v0/member_001_probe_playback.json"

    static func loadFixture() -> MLPlaybackPrototypeFixture? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(fixturePath, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            RuntimeEventLogger.log("ml_playback fixture_missing path=\(url.path)")
            return nil
        }

        do {
            return try JSONDecoder().decode(MLPlaybackPrototypeFixture.self, from: data)
        } catch {
            RuntimeEventLogger.log("ml_playback fixture_decode_failed error=\(error.localizedDescription)")
            return nil
        }
    }
}
