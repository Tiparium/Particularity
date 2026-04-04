import Foundation
import simd

enum DefaultPhysicsModuleRuntime {
    struct SpawnData {
        var activeCount: Int
        var particles: [ParticleState]
    }

    static func rebuildParticles(from state: SimulationViewportState) -> SpawnData {
        let count = max(1, state.particleCount)
        let typeCount = max(1, state.particleTypes)
        var particles: [ParticleState] = []
        particles.reserveCapacity(count)

        if state.randomDistribution {
            var generator = SeededGenerator(seed: UInt64(count * 37 + typeCount * 101))
            for index in 0..<count {
                let position = SIMD3<Float>(
                    Float.random(in: -0.98...0.98, using: &generator),
                    Float.random(in: -0.98...0.98, using: &generator),
                    Float.random(in: -0.98...0.98, using: &generator)
                )
                particles.append(
                    ParticleState(
                        position: position,
                        type: UInt32(index % typeCount),
                        particleID: UInt32(index),
                        active: 1
                    )
                )
            }
        } else {
            let sideCount = max(1, Int(ceil(pow(Double(count), 1.0 / 3.0))))
            let step = sideCount == 1 ? 0 : 1.96 / Float(sideCount - 1)
            let cellCount = sideCount * sideCount * sideCount

            for emitted in 0..<count {
                let normalizedIndex = count == 1 ? 0.0 : Double(emitted) / Double(count - 1)
                let latticeIndex = min(cellCount - 1, Int((normalizedIndex * Double(cellCount - 1)).rounded()))
                let z = latticeIndex / (sideCount * sideCount)
                let y = (latticeIndex / sideCount) % sideCount
                let x = latticeIndex % sideCount

                let position = SIMD3<Float>(
                    -0.98 + Float(x) * step,
                    -0.98 + Float(y) * step,
                    -0.98 + Float(z) * step
                )
                particles.append(
                    ParticleState(
                        position: position,
                        type: UInt32(emitted % typeCount),
                        particleID: UInt32(emitted),
                        active: 1
                    )
                )
            }
        }

        return SpawnData(activeCount: count, particles: particles)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x12345678abcdef : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
}
