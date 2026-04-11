struct PhysicsAccumulateParams {
    uint particleCount;
    float _padding1;
    float _padding2;
    uint neighborReadMode;
};

struct PhysicsApplyParams {
    float4 movementDirection;
    uint particleCount;
    float deltaTime;
    float velocityDamping;
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

kernel void physics_accumulate_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    device const uint *interactionGroupIndices [[buffer(2)]],
    device const uint *interactionRangeOffsets [[buffer(3)]],
    device const uint *interactionRangeTargets [[buffer(4)]],
    device const InteractionRangeEntry *interactionRanges [[buffer(5)]],
    device const uint *interactionIndices [[buffer(6)]],
    device const ParticleState *scratchParticles [[buffer(7)]],
    device const uint *scratchToCanonical [[buffer(8)]],
    constant PhysicsAccumulateParams& params [[buffer(9)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.particleCount) {
        return;
    }

    ParticleState source = sourceParticles[id];
    if (particle_active(source) == 0) {
        destinationParticles[id].impulse = float4(0.0);
        return;
    }

    float3 nextImpulse = float3(0.0);
    uint groupIndex = interactionGroupIndices[id];
    uint rangeStart = interactionRangeOffsets[groupIndex];
    uint rangeEnd = interactionRangeOffsets[groupIndex + 1];

    for (uint rangeIndex = rangeStart; rangeIndex < rangeEnd; ++rangeIndex) {
        uint targetGroupIndex = interactionRangeTargets[rangeIndex];
        InteractionRangeEntry rangeEntry = interactionRanges[targetGroupIndex];
        uint interactionEnd = rangeEntry.startIndex + rangeEntry.count;
        for (uint interactionOffset = rangeEntry.startIndex; interactionOffset < interactionEnd; ++interactionOffset) {
            uint targetIndex = interactionIndices[interactionOffset];
            if (targetIndex >= params.particleCount) {
                continue;
            }
            uint targetCanonicalIndex = interaction_resolve_canonical_index(
                targetIndex,
                scratchToCanonical,
                params.neighborReadMode
            );
            if (targetCanonicalIndex == id || targetCanonicalIndex >= params.particleCount) {
                continue;
            }
            ParticleState target = interaction_read_particle(
                targetIndex,
                sourceParticles,
                scratchParticles,
                params.neighborReadMode
            );
            if (particle_active(target) == 0) {
                continue;
            }
        }
    }

    destinationParticles[id].impulse = float4(nextImpulse, 0.0);
}

kernel void physics_apply_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    constant PhysicsApplyParams& params [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.particleCount) {
        return;
    }

    ParticleState particle = sourceParticles[id];
    if (particle_active(particle) == 0) {
        destinationParticles[id] = particle;
        destinationParticles[id].impulse = float4(0.0);
        return;
    }

    float3 driftDirection = params.movementDirection.xyz;
    float driftLengthSquared = dot(driftDirection, driftDirection);
    if (driftLengthSquared > 0.0000001) {
        driftDirection = normalize(driftDirection);
    } else {
        driftDirection = float3(0.0);
    }

    float3 nextVelocity = driftDirection;
    float3 nextPosition = particle.position.xyz + driftDirection * params.deltaTime;
    destinationParticles[id] = particle;
    destinationParticles[id].velocity = float4(nextVelocity, 0.0);
    destinationParticles[id].position = float4(
        wrap_axis(nextPosition.x),
        wrap_axis(nextPosition.y),
        wrap_axis(nextPosition.z),
        1.0
    );
    destinationParticles[id].impulse = float4(0.0);
}
