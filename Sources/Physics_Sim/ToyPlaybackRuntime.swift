import Foundation
import simd

struct PlaybackTimelineState: Equatable {
    var currentSeconds: Double = 0
    var durationSeconds: Double = 0
    var playbackRate: Double = 1
    var isLooping = true
    var sampleCount: Int?
    var currentSampleIndex: Int?
}

struct ToyPlaybackFrame {
    let sampleIndex: Int
    let timeSeconds: Double
    let particles: [ParticleState]
}

final class ToyPlaybackRuntime {
    private static let durationSeconds: Double = 8
    private static let sampleCount = 240
    private static let particleCount = 960

    var timeline: PlaybackTimelineState {
        PlaybackTimelineState(
            currentSeconds: 0,
            durationSeconds: Self.durationSeconds,
            playbackRate: 1,
            isLooping: true,
            sampleCount: Self.sampleCount,
            currentSampleIndex: nil
        )
    }

    func frame(at seconds: Double) -> ToyPlaybackFrame {
        let boundedSeconds = min(max(0, seconds), Self.durationSeconds)
        let normalizedTime = Self.durationSeconds > 0 ? boundedSeconds / Self.durationSeconds : 0
        let sampleIndex = min(
            Self.sampleCount - 1,
            max(0, Int((normalizedTime * Double(Self.sampleCount - 1)).rounded()))
        )
        return ToyPlaybackFrame(
            sampleIndex: sampleIndex,
            timeSeconds: boundedSeconds,
            particles: makeParticles(normalizedTime: normalizedTime)
        )
    }

    private func makeParticles(normalizedTime: Double) -> [ParticleState] {
        let columns = 40
        let rows = max(1, Self.particleCount / columns)
        let phase = Float(normalizedTime * Double.pi * 2)
        var particles: [ParticleState] = []
        particles.reserveCapacity(Self.particleCount)

        for index in 0..<Self.particleCount {
            let column = index % columns
            let row = index / columns
            let x = (Float(column) / Float(max(1, columns - 1)) - 0.5) * 1.7
            let z = (Float(row) / Float(max(1, rows - 1)) - 0.5) * 1.2
            let waveA = sin((x * 4.2) + phase)
            let waveB = cos((z * 5.1) - phase * 0.7)
            let y = (waveA + waveB) * 0.16
            let type = UInt32((column / 5 + row / 4 + Int(normalizedTime * 12)) % 12)
            particles.append(
                ParticleState(
                    position: SIMD3<Float>(x, y, z),
                    velocity: SIMD3<Float>(waveA, waveB, Float(normalizedTime)),
                    impulse: SIMD3<Float>(Float(row), Float(column), 0),
                    type: type,
                    particleID: UInt32(index),
                    active: 1
                )
            )
        }

        return particles
    }
}
