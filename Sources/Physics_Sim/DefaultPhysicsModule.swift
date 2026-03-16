import Foundation
import simd

enum DefaultPhysicsModuleRuntime {
    struct SpawnData {
        var activeCount: Int
        var positions: [SIMD4<Float>]
        var colors: [SIMD4<Float>]
    }

    static let computeShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PhysicsStepParams {
        float4 movementDirection;
        uint particleCount;
        float deltaTime;
    };

    static float wrap_axis(float value) {
        float wrapped = value;
        while (wrapped > 1.0) {
            wrapped -= 2.0;
        }
        while (wrapped < -1.0) {
            wrapped += 2.0;
        }
        return wrapped;
    }

    kernel void physics_step(
        device float4 *positions [[buffer(0)]],
        constant PhysicsStepParams& params [[buffer(1)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id >= params.particleCount) {
            return;
        }

        float3 direction = params.movementDirection.xyz;
        float lengthSquared = dot(direction, direction);
        if (lengthSquared > 0.0000001) {
            direction = normalize(direction);
        } else {
            direction = float3(0.0);
        }

        float3 next = positions[id].xyz + direction * params.deltaTime;
        positions[id] = float4(
            wrap_axis(next.x),
            wrap_axis(next.y),
            wrap_axis(next.z),
            1.0
        );
    }
    """

    static func rebuildParticles(from state: SimulationViewportState) -> SpawnData {
        let count = max(1, state.particleCount)
        let typeCount = max(1, state.particleTypes)
        var positions: [SIMD4<Float>] = []
        var colors: [SIMD4<Float>] = []
        positions.reserveCapacity(count)
        colors.reserveCapacity(count)

        if state.randomDistribution {
            var generator = SeededGenerator(seed: UInt64(count * 37 + typeCount * 101))
            for index in 0..<count {
                let position = SIMD3<Float>(
                    Float.random(in: -0.98...0.98, using: &generator),
                    Float.random(in: -0.98...0.98, using: &generator),
                    Float.random(in: -0.98...0.98, using: &generator)
                )
                positions.append(SIMD4<Float>(position.x, position.y, position.z, 1.0))
                colors.append(
                    DefaultVisualModuleRuntime.colorForType(
                        typeIndex: index % typeCount,
                        typeCount: typeCount,
                        spectrumOffset: state.spectrumOffset
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
                positions.append(SIMD4<Float>(position.x, position.y, position.z, 1.0))
                colors.append(
                    DefaultVisualModuleRuntime.colorForType(
                        typeIndex: emitted % typeCount,
                        typeCount: typeCount,
                        spectrumOffset: state.spectrumOffset
                    )
                )
            }
        }

        return SpawnData(activeCount: count, positions: positions, colors: colors)
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
