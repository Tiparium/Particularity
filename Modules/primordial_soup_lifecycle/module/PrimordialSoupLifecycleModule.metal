struct PrimordialSoupLifecycleRelationship {
    float signedForce;
    float energyCost;
    float threatContribution;
    float reserved0;
};

struct PrimordialSoupLifecycleTypeProfile {
    float maxSpeed;
    float motility;
    float innerRadius;
    float middleRadius;
    float outerRadius;
    float energyDecayRate;
    float reproductionEnergyThreshold;
    float reproductionEnergyCost;
    float childEnergyFraction;
    float reproductionCooldown;
    float threatSensitivity;
    float reserved0;
};

struct PrimordialSoupLifecycleSidecarState {
    float energy;
    float age;
    float reproductionCooldownRemaining;
    float interactionEnergyDelta;
};

struct PrimordialSoupLifecycleSpawnRecord {
    ParticleState particle;
    PrimordialSoupLifecycleSidecarState sidecar;
    uint targetSlot;
    uint reserved0;
    uint reserved1;
    uint reserved2;
};

struct PrimordialSoupLifecycleAccumulateParams {
    uint particleCount;
    uint particleTypeCount;
    uint neighborReadMode;
    uint _padding0;
    float innerRadiusMultiplier;
    float middleRadiusMultiplier;
    float outerRadiusMultiplier;
    float attractionMultiplier;
    float repulsionMultiplier;
    uint signedForceEnabled;
    uint energyCostEnabled;
    uint threatContributionEnabled;
    uint motilityEnabled;
    uint innerRadiusEnabled;
    uint middleRadiusEnabled;
    uint outerRadiusEnabled;
    uint _padding1;
};

struct PrimordialSoupLifecycleApplyParams {
    uint particleCount;
    uint particleTypeCount;
    uint initialActiveCount;
    uint spawnRecordCapacity;
    uint randomSeed;
    float deltaTime;
    uint dampingEnabled;
    uint momentumEnabled;
    uint speedLimitEnabled;
    float dampingStrength;
    float momentumStrength;
    float speedLimit;
    uint maxSpeedEnabled;
    uint energyDecayEnabled;
    uint reproductionThresholdEnabled;
    uint reproductionCostEnabled;
    uint childEnergyFractionEnabled;
    uint reproductionCooldownEnabled;
    uint threatSensitivityEnabled;
    uint _padding0;
};

struct PrimordialSoupLifecycleSpawnResolveParams {
    uint particleCount;
    uint spawnRecordCapacity;
};

static float wrap_axis_primordial_lifecycle(float value) {
    float wrapped = value;
    while (wrapped > 1.0) {
        wrapped -= 2.0;
    }
    while (wrapped < -1.0) {
        wrapped += 2.0;
    }
    return wrapped;
}

static float wrapped_delta_axis_primordial_lifecycle(float value) {
    if (value > 1.0) {
        return value - 2.0;
    }
    if (value < -1.0) {
        return value + 2.0;
    }
    return value;
}

static float3 wrapped_delta_primordial_lifecycle(float3 targetPosition, float3 sourcePosition) {
    float3 delta = targetPosition - sourcePosition;
    return float3(
        wrapped_delta_axis_primordial_lifecycle(delta.x),
        wrapped_delta_axis_primordial_lifecycle(delta.y),
        wrapped_delta_axis_primordial_lifecycle(delta.z)
    );
}

static uint hash_uint_primordial_lifecycle(uint value) {
    uint x = value;
    x ^= x >> 16;
    x *= 0x7feb352d;
    x ^= x >> 15;
    x *= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

static float hash_to_unit_float_primordial_lifecycle(uint value) {
    return float(hash_uint_primordial_lifecycle(value) & 0x00ffffff) / float(0x01000000);
}

static float3 random_unit_direction_primordial_lifecycle(uint seed) {
    float3 candidate = float3(
        hash_to_unit_float_primordial_lifecycle(seed * 5u + 29u) * 2.0 - 1.0,
        hash_to_unit_float_primordial_lifecycle(seed * 5u + 31u) * 2.0 - 1.0,
        hash_to_unit_float_primordial_lifecycle(seed * 5u + 37u) * 2.0 - 1.0
    );
    float lengthSquared = dot(candidate, candidate);
    if (lengthSquared <= 0.000001) {
        return float3(1.0, 0.0, 0.0);
    }
    return normalize(candidate);
}

static float normalized_falloff_primordial_lifecycle(float value, float range) {
    if (range <= 0.000001) {
        return 0.0;
    }
    return clamp(value / range, 0.0, 1.0);
}

static float blend_factor_primordial_lifecycle(float distance, float innerRadius, float middleRadius) {
    if (middleRadius <= 0.000001) {
        return 1.0;
    }
    return clamp((distance - innerRadius) / middleRadius, 0.0, 1.0);
}

kernel void primordial_soup_lifecycle_accumulate_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    device const uint *interactionGroupIndices [[buffer(2)]],
    device const uint *interactionRangeOffsets [[buffer(3)]],
    device const uint *interactionRangeTargets [[buffer(4)]],
    device const InteractionRangeEntry *interactionRanges [[buffer(5)]],
    device const uint *interactionIndices [[buffer(6)]],
    device const ParticleState *scratchParticles [[buffer(7)]],
    device const uint *scratchToCanonical [[buffer(8)]],
    device const PrimordialSoupLifecycleRelationship *relationships [[buffer(9)]],
    device const PrimordialSoupLifecycleTypeProfile *typeProfiles [[buffer(10)]],
    device const PrimordialSoupLifecycleSidecarState *sourceSidecar [[buffer(11)]],
    device PrimordialSoupLifecycleSidecarState *destinationSidecar [[buffer(12)]],
    constant PrimordialSoupLifecycleAccumulateParams& params [[buffer(13)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.particleCount) {
        return;
    }

    ParticleState source = sourceParticles[id];
    if (particle_active(source) == 0) {
        PrimordialSoupLifecycleSidecarState inactiveSidecar;
        inactiveSidecar.energy = 0.0;
        inactiveSidecar.age = 0.0;
        inactiveSidecar.reproductionCooldownRemaining = 0.0;
        inactiveSidecar.interactionEnergyDelta = 0.0;
        destinationSidecar[id] = inactiveSidecar;
        destinationParticles[id].impulse = float4(0.0);
        return;
    }

    uint sourceType = min(particle_type(source), params.particleTypeCount - 1);
    PrimordialSoupLifecycleTypeProfile sourceProfile = typeProfiles[sourceType];
    PrimordialSoupLifecycleSidecarState nextSidecar = sourceSidecar[id];
    nextSidecar.interactionEnergyDelta = 0.0;
    float innerLimit = params.innerRadiusEnabled != 0
        ? sourceProfile.innerRadius * params.innerRadiusMultiplier
        : 0.0;
    float middleWidth = params.middleRadiusEnabled != 0
        ? sourceProfile.middleRadius * params.middleRadiusMultiplier
        : 0.0;
    float outerWidth = params.outerRadiusEnabled != 0
        ? sourceProfile.outerRadius * params.outerRadiusMultiplier
        : 0.0;
    float middleLimit = innerLimit + middleWidth;
    float outerLimit = middleLimit + outerWidth;
    if (outerLimit <= 0.000001) {
        destinationSidecar[id] = nextSidecar;
        destinationParticles[id].impulse = float4(0.0);
        return;
    }

    float3 sourcePosition = source.position.xyz;
    float3 accumulatedImpulse = float3(0.0);
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

            float3 delta = wrapped_delta_primordial_lifecycle(target.position.xyz, sourcePosition);
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
                float repulsionT = 1.0 - normalized_falloff_primordial_lifecycle(distance, innerLimit);
                contribution = -params.repulsionMultiplier * repulsionT * direction;
                hadNonZeroInteraction = hadNonZeroInteraction || abs(params.repulsionMultiplier * repulsionT) > 0.000001;
            } else {
                uint targetType = min(particle_type(target), params.particleTypeCount - 1);
                PrimordialSoupLifecycleRelationship relationship = relationships[sourceType * params.particleTypeCount + targetType];
                float signedForce = params.signedForceEnabled != 0 ? relationship.signedForce : 0.0;
                if (signedForce > 0.0) {
                    signedForce *= params.attractionMultiplier;
                } else if (signedForce < 0.0) {
                    signedForce *= params.repulsionMultiplier;
                }

                float interactionSpan = middleWidth + outerWidth;
                float interactionT = normalized_falloff_primordial_lifecycle(distance - innerLimit, interactionSpan);
                float3 relationshipVector = signedForce * interactionT * direction;

                if (distance <= middleLimit) {
                    float middleT = blend_factor_primordial_lifecycle(distance, innerLimit, middleWidth);
                    contribution = relationshipVector * middleT;
                } else {
                    contribution = relationshipVector;
                }
                float energyT = 1.0 - normalized_falloff_primordial_lifecycle(distance - innerLimit, interactionSpan);
                if (params.energyCostEnabled != 0) {
                    nextSidecar.interactionEnergyDelta -= relationship.energyCost * max(0.0, energyT);
                }
                hadNonZeroInteraction = hadNonZeroInteraction || length_squared(contribution) > 0.000001;
            }

            float motilityMultiplier = params.motilityEnabled != 0
                ? max(0.0, sourceProfile.motility + 1.0)
                : 1.0;
            accumulatedImpulse += contribution * motilityMultiplier;
        }
    }

    destinationSidecar[id] = nextSidecar;
    destinationParticles[id].impulse = float4(accumulatedImpulse, hadNonZeroInteraction ? 0.0 : 1.0);
}

kernel void primordial_soup_lifecycle_apply_impulse(
    device const ParticleState *sourceParticles [[buffer(0)]],
    device ParticleState *destinationParticles [[buffer(1)]],
    device const PrimordialSoupLifecycleTypeProfile *typeProfiles [[buffer(2)]],
    device PrimordialSoupLifecycleSidecarState *sidecar [[buffer(3)]],
    device PrimordialSoupLifecycleSpawnRecord *spawnRecords [[buffer(4)]],
    device atomic_uint *frameSpawnCounter [[buffer(5)]],
    device atomic_uint *nextSpawnSlotCounter [[buffer(6)]],
    constant PrimordialSoupLifecycleApplyParams& params [[buffer(7)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.particleCount) {
        return;
    }

    ParticleState particle = sourceParticles[id];
    if (particle_active(particle) == 0) {
        destinationParticles[id] = particle;
        destinationParticles[id].impulse = float4(0.0);
        sidecar[id].energy = 0.0;
        sidecar[id].age = 0.0;
        sidecar[id].reproductionCooldownRemaining = 0.0;
        sidecar[id].interactionEnergyDelta = 0.0;
        return;
    }

    uint sourceType = min(particle_type(particle), params.particleTypeCount - 1);
    PrimordialSoupLifecycleTypeProfile profile = typeProfiles[sourceType];
    PrimordialSoupLifecycleSidecarState nextSidecar = sidecar[id];
    nextSidecar.age += params.deltaTime;
    nextSidecar.reproductionCooldownRemaining = max(
        0.0,
        nextSidecar.reproductionCooldownRemaining - params.deltaTime
    );
    nextSidecar.energy += nextSidecar.interactionEnergyDelta;
    if (params.energyDecayEnabled != 0) {
        nextSidecar.energy -= profile.energyDecayRate * params.deltaTime * 60.0;
    }
    nextSidecar.interactionEnergyDelta = 0.0;

    if (nextSidecar.energy <= 0.0) {
        particle.metadata.z = 0;
        destinationParticles[id] = particle;
        destinationParticles[id].velocity = float4(0.0);
        destinationParticles[id].impulse = float4(0.0);
        nextSidecar.energy = 0.0;
        nextSidecar.reproductionCooldownRemaining = 0.0;
        sidecar[id] = nextSidecar;
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
        float typeSpeedLimit = params.maxSpeedEnabled != 0
            ? max(0.000001, min(params.speedLimit, profile.maxSpeed))
            : max(0.000001, params.speedLimit);
        if (speed > typeSpeedLimit) {
            nextVelocity = (nextVelocity / speed) * typeSpeedLimit;
        }
    }

    float3 nextPosition = particle.position.xyz + nextVelocity * params.deltaTime;
    destinationParticles[id] = particle;
    destinationParticles[id].velocity = float4(nextVelocity, 0.0);
    destinationParticles[id].position = float4(
        wrap_axis_primordial_lifecycle(nextPosition.x),
        wrap_axis_primordial_lifecycle(nextPosition.y),
        wrap_axis_primordial_lifecycle(nextPosition.z),
        1.0
    );
    destinationParticles[id].impulse = float4(0.0);
    sidecar[id] = nextSidecar;

    float threshold = params.reproductionThresholdEnabled != 0
        ? max(0.000001, profile.reproductionEnergyThreshold)
        : 1.0;
    float surplus = max(0.0, nextSidecar.energy - threshold);
    if (surplus <= 0.0) {
        return;
    }

    float cooldownWindow = params.reproductionCooldownEnabled != 0
        ? max(0.000001, profile.reproductionCooldown)
        : 0.0;
    float cooldownReadiness = params.reproductionCooldownEnabled != 0
        ? 1.0 - clamp(nextSidecar.reproductionCooldownRemaining / max(0.000001, cooldownWindow), 0.0, 1.0)
        : 1.0;
    float surplusReadiness = clamp(surplus / threshold, 0.0, 1.0);
    float reproductionProbability = 0.045 * params.deltaTime * 60.0 * cooldownReadiness * surplusReadiness;
    uint rollSeed = particle_id(particle)
        ^ hash_uint_primordial_lifecycle(params.randomSeed + 0x9e3779b9u)
        ^ hash_uint_primordial_lifecycle(as_type<uint>(nextSidecar.energy))
        ^ hash_uint_primordial_lifecycle(as_type<uint>(particle.position.x) + 101u)
        ^ hash_uint_primordial_lifecycle(as_type<uint>(particle.position.y) + 211u)
        ^ hash_uint_primordial_lifecycle(as_type<uint>(particle.position.z) + 307u);
    if (hash_to_unit_float_primordial_lifecycle(rollSeed) >= reproductionProbability) {
        return;
    }

    uint targetSlot = params.initialActiveCount + atomic_fetch_add_explicit(
        nextSpawnSlotCounter,
        1u,
        memory_order_relaxed
    );
    if (targetSlot >= params.particleCount) {
        return;
    }

    uint recordIndex = atomic_fetch_add_explicit(frameSpawnCounter, 1u, memory_order_relaxed);
    if (recordIndex >= params.spawnRecordCapacity) {
        return;
    }

    PrimordialSoupLifecycleSidecarState parentSidecar = sidecar[id];
    float reproductionCost = params.reproductionCostEnabled != 0
        ? max(0.0, profile.reproductionEnergyCost)
        : 0.0;
    float childFraction = params.childEnergyFractionEnabled != 0
        ? clamp(profile.childEnergyFraction, 0.0, 1.0)
        : 0.5;
    float childEnergyBase = params.reproductionCostEnabled != 0
        ? max(reproductionCost, 0.02)
        : threshold * 0.5;
    float childEnergy = max(0.02, childEnergyBase * childFraction);
    parentSidecar.energy = max(0.0, parentSidecar.energy - reproductionCost);
    parentSidecar.reproductionCooldownRemaining = cooldownWindow;
    sidecar[id] = parentSidecar;

    float3 childDirection = random_unit_direction_primordial_lifecycle(rollSeed + 911u);
    float childOffset = max(0.002, profile.innerRadius * 0.55);
    float3 childPosition = particle.position.xyz + childDirection * childOffset;
    ParticleState child = particle;
    child.position = float4(
        wrap_axis_primordial_lifecycle(childPosition.x),
        wrap_axis_primordial_lifecycle(childPosition.y),
        wrap_axis_primordial_lifecycle(childPosition.z),
        1.0
    );
    child.velocity = float4(childDirection * min(profile.maxSpeed, 0.08), 0.0);
    child.impulse = float4(0.0);
    child.metadata = uint4(sourceType, targetSlot, 1u, 0u);

    PrimordialSoupLifecycleSidecarState childSidecar;
    childSidecar.energy = childEnergy;
    childSidecar.age = 0.0;
    childSidecar.reproductionCooldownRemaining = cooldownWindow;
    childSidecar.interactionEnergyDelta = 0.0;

    spawnRecords[recordIndex].particle = child;
    spawnRecords[recordIndex].sidecar = childSidecar;
    spawnRecords[recordIndex].targetSlot = targetSlot;
    spawnRecords[recordIndex].reserved0 = 0u;
    spawnRecords[recordIndex].reserved1 = 0u;
    spawnRecords[recordIndex].reserved2 = 0u;
}

kernel void primordial_soup_lifecycle_resolve_spawns(
    device ParticleState *particles [[buffer(0)]],
    device PrimordialSoupLifecycleSidecarState *sidecar [[buffer(1)]],
    device const PrimordialSoupLifecycleSpawnRecord *spawnRecords [[buffer(2)]],
    device const atomic_uint *frameSpawnCounter [[buffer(3)]],
    constant PrimordialSoupLifecycleSpawnResolveParams& params [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    uint spawnCount = min(
        atomic_load_explicit(frameSpawnCounter, memory_order_relaxed),
        params.spawnRecordCapacity
    );
    if (id >= spawnCount) {
        return;
    }

    PrimordialSoupLifecycleSpawnRecord record = spawnRecords[id];
    if (record.targetSlot >= params.particleCount) {
        return;
    }

    particles[record.targetSlot] = record.particle;
    sidecar[record.targetSlot] = record.sidecar;
}
