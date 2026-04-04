struct TypeMatrixPhysicsAccumulateParams {
    uint particleCount;
    uint particleTypeCount;
    float innerRadius;
    float middleRadius;
    float outerRadius;
    float attractionMultiplier;
    float repulsionMultiplier;
    uint interactionTraversalMode;
    uint matrixSideLength;
};

struct TypeMatrixPhysicsApplyParams {
    uint particleCount;
    float deltaTime;
    uint dampingEnabled;
    uint momentumEnabled;
    uint speedLimitEnabled;
    float dampingStrength;
    float momentumStrength;
    float speedLimit;
};

static float wrap_axis_type_matrix(float value) {
    float wrapped = value;
    while (wrapped > 1.0) {
        wrapped -= 2.0;
    }
    while (wrapped < -1.0) {
        wrapped += 2.0;
    }
    return wrapped;
}

static float wrapped_delta_axis(float value) {
    if (value > 1.0) {
        return value - 2.0;
    }
    if (value < -1.0) {
        return value + 2.0;
    }
    return value;
}

static float3 wrapped_delta(float3 targetPosition, float3 sourcePosition) {
    float3 delta = targetPosition - sourcePosition;
    return float3(
        wrapped_delta_axis(delta.x),
        wrapped_delta_axis(delta.y),
        wrapped_delta_axis(delta.z)
    );
}

static float blend_factor(float distance, float innerRadius, float middleRadius) {
    if (middleRadius <= 0.000001) {
        return 1.0;
    }
    return clamp((distance - innerRadius) / middleRadius, 0.0, 1.0);
}

static float normalized_falloff(float value, float range) {
    if (range <= 0.000001) {
        return 0.0;
    }
    return clamp(value / range, 0.0, 1.0);
}

kernel void type_matrix_accumulate_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    device const uint *interactionOffsets [[buffer(2)]],
    device const uint *interactionIndices [[buffer(3)]],
    device const int *interactionMatrix [[buffer(4)]],
    constant TypeMatrixPhysicsAccumulateParams& params [[buffer(5)]],
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

    float innerLimit = params.innerRadius;
    float middleLimit = innerLimit + params.middleRadius;
    float outerLimit = middleLimit + params.outerRadius;
    if (outerLimit <= 0.000001) {
        destinationParticles[id].impulse = float4(0.0);
        return;
    }

    float3 sourcePosition = source.position.xyz;
    float3 accumulatedImpulse = float3(0.0);
    uint sourceType = min(particle_type(source), params.particleTypeCount - 1);

    for (uint interactionOffset = interactionOffsets[id]; interactionOffset < interactionOffsets[id + 1]; ++interactionOffset) {
        uint targetIndex = params.interactionTraversalMode == 1
            ? interactionOffset - interactionOffsets[id]
            : interactionIndices[interactionOffset];
        if (targetIndex == id || targetIndex >= params.particleCount) {
            continue;
        }

        ParticleState target = sourceParticles[targetIndex];
        if (particle_active(target) == 0) {
            continue;
        }

        float3 delta = wrapped_delta(target.position.xyz, sourcePosition);
        float distanceSquared = dot(delta, delta);
        if (distanceSquared < 0.000001) {
            continue;
        }

        float distance = sqrt(distanceSquared);
        if (distance > outerLimit) {
            continue;
        }

        float3 direction = normalize(delta);
        float3 contribution = float3(0.0);
        if (distance <= innerLimit) {
            float repulsionT = 1.0 - normalized_falloff(distance, innerLimit);
            contribution = -params.repulsionMultiplier * repulsionT * direction;
        } else {
            uint targetType = min(particle_type(target), params.particleTypeCount - 1);
            int matrixValue = interactionMatrix[sourceType * params.matrixSideLength + targetType];
            float scaledMatrixValue = float(matrixValue);
            if (matrixValue > 0) {
                scaledMatrixValue *= params.attractionMultiplier;
            } else if (matrixValue < 0) {
                scaledMatrixValue *= params.repulsionMultiplier;
            }

            float interactionSpan = params.middleRadius + params.outerRadius;
            float interactionT = normalized_falloff(distance - innerLimit, interactionSpan);
            float3 matrixVector = scaledMatrixValue * interactionT * direction;

            if (distance <= middleLimit) {
                float middleT = blend_factor(distance, innerLimit, params.middleRadius);
                contribution = matrixVector * middleT;
            } else {
                contribution = matrixVector;
            }
        }

        accumulatedImpulse += contribution;
    }

    destinationParticles[id].impulse = float4(accumulatedImpulse, 0.0);
}

kernel void type_matrix_apply_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    constant TypeMatrixPhysicsApplyParams& params [[buffer(2)]],
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

    float3 previousVelocity = particle.velocity.xyz;
    float3 nextVelocity = previousVelocity + destinationParticles[id].impulse.xyz;
    if (params.dampingEnabled != 0) {
        nextVelocity *= params.dampingStrength;
    }
    if (params.momentumEnabled != 0) {
        nextVelocity = mix(nextVelocity, previousVelocity, clamp(params.momentumStrength, 0.0, 1.0));
    }
    if (params.speedLimitEnabled != 0) {
        float speed = length(nextVelocity);
        if (params.speedLimit > 0.000001 && speed > params.speedLimit) {
            nextVelocity = (nextVelocity / speed) * params.speedLimit;
        }
    }
    float3 nextPosition = particle.position.xyz + nextVelocity * params.deltaTime;
    destinationParticles[id] = particle;
    destinationParticles[id].velocity = float4(nextVelocity, 0.0);
    destinationParticles[id].position = float4(
        wrap_axis_type_matrix(nextPosition.x),
        wrap_axis_type_matrix(nextPosition.y),
        wrap_axis_type_matrix(nextPosition.z),
        1.0
    );
    destinationParticles[id].impulse = float4(0.0);
}
