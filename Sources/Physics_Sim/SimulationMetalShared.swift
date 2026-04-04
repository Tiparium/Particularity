import Foundation

enum SimulationMetalSharedSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct ParticleState {
        float4 position;
        float4 velocity;
        float4 impulse;
        uint4 metadata;
    };

    inline uint particle_type(thread const ParticleState& particle) {
        return particle.metadata.x;
    }

    inline uint particle_id(thread const ParticleState& particle) {
        return particle.metadata.y;
    }

    inline uint particle_active(thread const ParticleState& particle) {
        return particle.metadata.z;
    }
    """
}
