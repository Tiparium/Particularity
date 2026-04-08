struct TypeMatrixPhysicsAccumulateParams {
    uint particleCount;
    uint particleTypeCount;
    float innerRadius;
    float middleRadius;
    float outerRadius;
    float attractionMultiplier;
    float repulsionMultiplier;
    uint matrixSideLength;
    uint teleportationEnabled;
    uint teleportationGeneralBudget;
    uint teleportationSelfBudget;
    uint teleportationSelfBudgetLinked;
    float teleportationAccumulation;
    float teleportationRecoveryRate;
};

struct TypeMatrixLocalSidecarState {
    float teleportAccumulation;
    float interactionFuel;
    float reserved0;
    float reserved1;
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
    uint teleportationEnabled;
    float teleportationMinimumDistance;
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

static uint hash_uint(uint value) {
    uint x = value;
    x ^= x >> 16;
    x *= 0x7feb352d;
    x ^= x >> 15;
    x *= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

static float hash_to_unit_float(uint value) {
    return float(hash_uint(value) & 0x00ffffff) / float(0x01000000);
}

static float3 random_position_from_seed(uint seed) {
    return float3(
        hash_to_unit_float(seed * 3u + 11u) * 2.0 - 1.0,
        hash_to_unit_float(seed * 3u + 17u) * 2.0 - 1.0,
        hash_to_unit_float(seed * 3u + 23u) * 2.0 - 1.0
    );
}

static float3 random_unit_direction_from_seed(uint seed) {
    float3 candidate = float3(
        hash_to_unit_float(seed * 5u + 29u) * 2.0 - 1.0,
        hash_to_unit_float(seed * 5u + 31u) * 2.0 - 1.0,
        hash_to_unit_float(seed * 5u + 37u) * 2.0 - 1.0
    );
    float candidateLengthSquared = dot(candidate, candidate);
    if (candidateLengthSquared <= 0.000001) {
        return float3(1.0, 0.0, 0.0);
    }
    return normalize(candidate);
}

kernel void type_matrix_accumulate_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    device const uint *interactionGroupIndices [[buffer(2)]],
    device const uint *interactionRangeOffsets [[buffer(3)]],
    device const uint *interactionRangeTargets [[buffer(4)]],
    device const InteractionRangeEntry *interactionRanges [[buffer(5)]],
    device const uint *interactionIndices [[buffer(6)]],
    device const int *interactionMatrix [[buffer(7)]],
    device const TypeMatrixLocalSidecarState *sourceSidecar [[buffer(8)]],
    device TypeMatrixLocalSidecarState *destinationSidecar [[buffer(9)]],
    constant TypeMatrixPhysicsAccumulateParams& params [[buffer(10)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.particleCount) {
        return;
    }

    ParticleState source = sourceParticles[id];
    if (particle_active(source) == 0) {
        if (params.teleportationEnabled != 0) {
            destinationSidecar[id].teleportAccumulation = 0.0;
        }
        destinationParticles[id].impulse = float4(0.0);
        return;
    }

    float innerLimit = params.innerRadius;
    float middleLimit = innerLimit + params.middleRadius;
    float outerLimit = middleLimit + params.outerRadius;
    if (outerLimit <= 0.000001) {
        if (params.teleportationEnabled != 0) {
            destinationSidecar[id].teleportAccumulation = 0.0;
        }
        destinationParticles[id].impulse = float4(0.0);
        return;
    }

    float3 sourcePosition = source.position.xyz;
    float3 accumulatedImpulse = float3(0.0);
    uint sourceType = min(particle_type(source), params.particleTypeCount - 1);
    uint sameTypeInteractionCount = 0;
    uint nonSelfInteractionCount = 0;
    TypeMatrixLocalSidecarState nextSidecar = sourceSidecar[id];
    float persistentTeleportAccumulation = params.teleportationEnabled != 0 ? nextSidecar.teleportAccumulation : 0.0;
    uint overBudgetInteractionCount = 0;
    bool hadNonZeroInteraction = false;

    uint groupIndex = interactionGroupIndices[id];
    uint rangeStart = interactionRangeOffsets[groupIndex];
    uint rangeEnd = interactionRangeOffsets[groupIndex + 1];
    for (uint rangeIndex = rangeStart; rangeIndex < rangeEnd; ++rangeIndex) {
        uint targetGroupIndex = interactionRangeTargets[rangeIndex];
        InteractionRangeEntry rangeEntry = interactionRanges[targetGroupIndex];
        uint interactionEnd = rangeEntry.startIndex + rangeEntry.count;
        for (uint interactionOffset = rangeEntry.startIndex; interactionOffset < interactionEnd; ++interactionOffset) {
            uint targetIndex = interactionIndices[interactionOffset];
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
                hadNonZeroInteraction = hadNonZeroInteraction || abs(params.repulsionMultiplier * repulsionT) > 0.000001;
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
                hadNonZeroInteraction = hadNonZeroInteraction || length_squared(contribution) > 0.000001;
            }

            if (params.teleportationEnabled != 0) {
                uint targetType = min(particle_type(target), params.particleTypeCount - 1);
                bool sameTypeInteraction = targetType == sourceType;
                if (sameTypeInteraction) {
                    sameTypeInteractionCount += 1;
                    if (sameTypeInteractionCount > params.teleportationSelfBudget) {
                        overBudgetInteractionCount += 1;
                    }
                } else {
                    nonSelfInteractionCount += 1;
                    if (nonSelfInteractionCount > params.teleportationGeneralBudget) {
                        overBudgetInteractionCount += 1;
                    }
                }
            }

            accumulatedImpulse += contribution;
        }
    }

    if (params.teleportationEnabled != 0) {
        if (overBudgetInteractionCount > 0) {
            for (uint count = 0; count < overBudgetInteractionCount; ++count) {
                if (persistentTeleportAccumulation <= 0.000001) {
                    persistentTeleportAccumulation = clamp(params.teleportationAccumulation, 0.0, 1.0);
                } else {
                    persistentTeleportAccumulation = clamp(
                        persistentTeleportAccumulation * (1.0 + params.teleportationAccumulation),
                        0.0,
                        1.0
                    );
                }
            }
        } else {
            persistentTeleportAccumulation = max(0.0, persistentTeleportAccumulation - params.teleportationRecoveryRate);
        }
    } else {
        persistentTeleportAccumulation = 0.0;
    }

    if (params.teleportationEnabled != 0) {
        nextSidecar.teleportAccumulation = persistentTeleportAccumulation;
    } else {
        nextSidecar.teleportAccumulation = 0.0;
    }
    destinationSidecar[id] = nextSidecar;
    destinationParticles[id].impulse = float4(accumulatedImpulse, hadNonZeroInteraction ? 0.0 : 1.0);
}

kernel void type_matrix_apply_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    device TypeMatrixLocalSidecarState *sidecar [[buffer(2)]],
    constant TypeMatrixPhysicsApplyParams& params [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.particleCount) {
        return;
    }

    ParticleState particle = sourceParticles[id];
    if (particle_active(particle) == 0) {
        if (params.teleportationEnabled != 0) {
            sidecar[id].teleportAccumulation = 0.0;
        }
        destinationParticles[id] = particle;
        destinationParticles[id].impulse = float4(0.0);
        return;
    }

    float3 previousVelocity = particle.velocity.xyz;
    float3 nextVelocity = previousVelocity + destinationParticles[id].impulse.xyz;

    if (destinationParticles[id].impulse.w > 0.5) {
        constexpr float driftStrength = 0.0035;
        constexpr float driftMomentumBias = 0.72;
        uint driftSeed = particle_id(particle)
            ^ hash_uint(as_type<uint>(particle.position.x) + 101u)
            ^ hash_uint(as_type<uint>(particle.position.y) + 211u)
            ^ hash_uint(as_type<uint>(particle.position.z) + 307u)
            ^ hash_uint(as_type<uint>(previousVelocity.x) + 401u)
            ^ hash_uint(as_type<uint>(previousVelocity.y) + 503u)
            ^ hash_uint(as_type<uint>(previousVelocity.z) + 601u);
        float3 randomDirection = random_unit_direction_from_seed(driftSeed);
        float previousSpeedSquared = dot(previousVelocity, previousVelocity);
        float3 weightedDirection = randomDirection;
        if (previousSpeedSquared > 0.000001) {
            float3 momentumDirection = normalize(previousVelocity);
            weightedDirection = normalize(mix(randomDirection, momentumDirection, driftMomentumBias));
        }
        nextVelocity += weightedDirection * driftStrength;
    }

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

    if (params.teleportationEnabled != 0) {
        float teleportProbability = clamp(sidecar[id].teleportAccumulation, 0.0, 1.0);
        if (teleportProbability > 0.000001) {
            uint seedBase = particle_id(particle)
                ^ hash_uint(as_type<uint>(nextPosition.x))
                ^ hash_uint(as_type<uint>(nextPosition.y) + 31u)
                ^ hash_uint(as_type<uint>(nextPosition.z) + 73u);
            float teleportRoll = hash_to_unit_float(seedBase + 97u);
            if (teleportRoll < teleportProbability) {
                float minimumDistance = max(0.0, params.teleportationMinimumDistance);
                float3 chosenPosition = nextPosition;
                bool foundCandidate = false;
                for (uint attempt = 0; attempt < 6u; ++attempt) {
                    float3 candidate = random_position_from_seed(seedBase + 131u * (attempt + 1u));
                    float3 teleportDelta = wrapped_delta(candidate, particle.position.xyz);
                    if (length(teleportDelta) >= minimumDistance) {
                        chosenPosition = candidate;
                        foundCandidate = true;
                        break;
                    }
                }
                if (!foundCandidate) {
                    chosenPosition = random_position_from_seed(seedBase + 911u);
                }
                nextPosition = chosenPosition;
                nextVelocity = float3(0.0);
                sidecar[id].teleportAccumulation = 0.0;
            }
        }
    } else {
        sidecar[id].teleportAccumulation = 0.0;
    }

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
