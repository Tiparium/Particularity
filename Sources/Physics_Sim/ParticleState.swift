import simd

struct ParticleState {
    var position: SIMD4<Float>
    var velocity: SIMD4<Float>
    var impulse: SIMD4<Float>
    var metadata: SIMD4<UInt32>

    init(
        position: SIMD3<Float>,
        velocity: SIMD3<Float> = .zero,
        impulse: SIMD3<Float> = .zero,
        type: UInt32,
        particleID: UInt32,
        active: UInt32 = 1
    ) {
        self.position = SIMD4<Float>(position.x, position.y, position.z, 1.0)
        self.velocity = SIMD4<Float>(velocity.x, velocity.y, velocity.z, 0.0)
        self.impulse = SIMD4<Float>(impulse.x, impulse.y, impulse.z, 0.0)
        self.metadata = SIMD4<UInt32>(type, particleID, active, 0)
    }

    var type: UInt32 {
        get { metadata.x }
        set { metadata.x = newValue }
    }

    var particleID: UInt32 {
        get { metadata.y }
        set { metadata.y = newValue }
    }

    var active: UInt32 {
        get { metadata.z }
        set { metadata.z = newValue }
    }
}
