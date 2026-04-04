struct TemplatePhysicsAccumulateParams {
    uint particleCount;
    uint interactionTraversalMode;
    float interactionRadius;
    float impulseScale;
};

struct TemplatePhysicsApplyParams {
    uint particleCount;
    float deltaTime;
    float velocityDamping;
    float _padding0;
};

static float wrap_axis_template(float value) {
    float wrapped = value;
    while (wrapped > 1.0) {
        wrapped -= 2.0;
    }
    while (wrapped < -1.0) {
        wrapped += 2.0;
    }
    return wrapped;
}

static float3 wrapped_delta_template(float3 targetPosition, float3 sourcePosition) {
    float3 delta = targetPosition - sourcePosition;
    if (delta.x > 1.0) { delta.x -= 2.0; }
    if (delta.x < -1.0) { delta.x += 2.0; }
    if (delta.y > 1.0) { delta.y -= 2.0; }
    if (delta.y < -1.0) { delta.y += 2.0; }
    if (delta.z > 1.0) { delta.z -= 2.0; }
    if (delta.z < -1.0) { delta.z += 2.0; }
    return delta;
}

kernel void template_physics_accumulate_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    device const uint *interactionOffsets [[buffer(2)]],
    device const uint *interactionIndices [[buffer(3)]],
    constant TemplatePhysicsAccumulateParams& params [[buffer(4)]],
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

    float3 accumulatedImpulse = float3(0.0);
    uint start = interactionOffsets[id];
    uint end = interactionOffsets[id + 1];

    for (uint interactionOffset = start; interactionOffset < end; ++interactionOffset) {
        uint targetIndex = params.interactionTraversalMode == 1
            ? interactionOffset - start
            : interactionIndices[interactionOffset];
        if (targetIndex == id || targetIndex >= params.particleCount) {
            continue;
        }

        ParticleState target = sourceParticles[targetIndex];
        if (particle_active(target) == 0) {
            continue;
        }

        // Replace this section with the module's actual interaction law.
        // The template currently uses a tiny distance-falloff attraction so the
        // module is visibly alive after selection, but still clearly unfinished.
        float3 delta = wrapped_delta_template(target.position.xyz, source.position.xyz);
        float distanceSquared = dot(delta, delta);
        if (distanceSquared < 0.000001) {
            continue;
        }

        float distance = sqrt(distanceSquared);
        if (distance > params.interactionRadius) {
            continue;
        }

        float reachT = 1.0 - clamp(distance / max(params.interactionRadius, 0.000001), 0.0, 1.0);
        accumulatedImpulse += normalize(delta) * (reachT * params.impulseScale);
    }

    destinationParticles[id].impulse = float4(accumulatedImpulse, 0.0);
}

kernel void template_physics_apply_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    constant TemplatePhysicsApplyParams& params [[buffer(2)]],
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

    // Replace this section with whatever "apply accumulated result to self"
    // means for the new module. The default here is a simple velocity update.
    float3 nextVelocity = (particle.velocity.xyz + destinationParticles[id].impulse.xyz) * params.velocityDamping;
    float3 nextPosition = particle.position.xyz + nextVelocity * params.deltaTime;

    destinationParticles[id] = particle;
    destinationParticles[id].velocity = float4(nextVelocity, 0.0);
    destinationParticles[id].position = float4(
        wrap_axis_template(nextPosition.x),
        wrap_axis_template(nextPosition.y),
        wrap_axis_template(nextPosition.z),
        1.0
    );
    destinationParticles[id].impulse = float4(0.0);
}
