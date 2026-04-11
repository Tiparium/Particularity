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

    struct InteractionRangeEntry {
        uint startIndex;
        uint count;
    };

    constant uint interaction_neighbor_read_mode_raw = 0u;
    constant uint interaction_neighbor_read_mode_scratch = 1u;

    inline uint interaction_resolve_canonical_index(
        uint candidateIndex,
        device const uint *scratchToCanonical,
        uint neighborReadMode
    ) {
        if (neighborReadMode == interaction_neighbor_read_mode_scratch) {
            return scratchToCanonical[candidateIndex];
        }
        return candidateIndex;
    }

    inline ParticleState interaction_read_particle(
        uint candidateIndex,
        device const ParticleState *canonicalParticles,
        device const ParticleState *scratchParticles,
        uint neighborReadMode
    ) {
        if (neighborReadMode == interaction_neighbor_read_mode_scratch) {
            return scratchParticles[candidateIndex];
        }
        return canonicalParticles[candidateIndex];
    }

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
