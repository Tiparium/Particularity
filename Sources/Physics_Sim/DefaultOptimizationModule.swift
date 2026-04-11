import Foundation

struct InteractionRangeEntry: Equatable, Sendable {
    var startIndex: UInt32
    var count: UInt32
}

struct OptimizationInteractionPlanData: Sendable {
    var groupIndices: [UInt32]
    var rangeOffsets: [UInt32]
    var rangeTargets: [UInt32]
    var ranges: [InteractionRangeEntry]
    var indices: [UInt32]
}

enum DefaultOptimizationModuleRuntime {
    static let computeShaderSource = """
    struct OptimizationDebugLineParams {
        uint segmentCount;
        uint particleCount;
        uint neighborReadMode;
        uint _padding1;
    };

    struct OptimizationDebugLineSegment {
        uint sourceParticleIndex;
        uint interactionCount;
        uint firstVertexIndex;
        uint _padding0;
        uint _padding1;
        uint _padding2;
        uint _padding3;
    };

    struct OptimizationLineVertex {
        float3 position;
    };

    static uint resolve_interaction_target_index(
        device const uint *groupIndices,
        device const uint *rangeOffsets,
        device const uint *rangeTargets,
        device const InteractionRangeEntry *ranges,
        device const uint *interactionIndices,
        uint sourceParticleIndex,
        uint interactionIndex
    ) {
        uint groupIndex = groupIndices[sourceParticleIndex];
        uint rangeOffset = rangeOffsets[groupIndex];
        uint rangeEnd = rangeOffsets[groupIndex + 1];
        uint remaining = interactionIndex;
        for (uint rangeIndex = rangeOffset; rangeIndex < rangeEnd; ++rangeIndex) {
            uint targetGroupIndex = rangeTargets[rangeIndex];
            InteractionRangeEntry rangeEntry = ranges[targetGroupIndex];
            if (remaining < rangeEntry.count) {
                return interactionIndices[rangeEntry.startIndex + remaining];
            }
            remaining -= rangeEntry.count;
        }
        return 0;
    }

    kernel void build_debug_lines(
        device const ParticleState *canonicalParticles [[buffer(0)]],
        device const uint *interactionGroupIndices [[buffer(1)]],
        device const uint *interactionRangeOffsets [[buffer(2)]],
        device const uint *interactionRangeTargets [[buffer(3)]],
        device const InteractionRangeEntry *interactionRanges [[buffer(4)]],
        device const uint *interactionIndices [[buffer(5)]],
        device const ParticleState *scratchParticles [[buffer(6)]],
        device const uint *scratchToCanonical [[buffer(7)]],
        device OptimizationLineVertex *lineVertices [[buffer(8)]],
        constant OptimizationDebugLineParams& params [[buffer(9)]],
        device const OptimizationDebugLineSegment *segments [[buffer(10)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (params.segmentCount == 0) {
            return;
        }

        OptimizationDebugLineSegment segment = segments[0];
        bool found = false;
        for (uint segmentIndex = 0; segmentIndex < params.segmentCount; ++segmentIndex) {
            OptimizationDebugLineSegment candidate = segments[segmentIndex];
            uint candidateVertexCount = candidate.interactionCount * 2;
            if (id >= candidate.firstVertexIndex && id < candidate.firstVertexIndex + candidateVertexCount) {
                segment = candidate;
                found = true;
                break;
            }
        }

        if (!found || segment.interactionCount == 0) {
            return;
        }

        uint localVertexIndex = id - segment.firstVertexIndex;
        uint interactionIndex = localVertexIndex / 2;
        uint particleIndex = segment.sourceParticleIndex;
        float3 sourcePosition = canonicalParticles[segment.sourceParticleIndex].position.xyz;
        float3 outputPosition = sourcePosition;

        if ((localVertexIndex % 2) != 0) {
            particleIndex = resolve_interaction_target_index(
                interactionGroupIndices,
                interactionRangeOffsets,
                interactionRangeTargets,
                interactionRanges,
                interactionIndices,
                segment.sourceParticleIndex,
                interactionIndex
            );
            if (particleIndex >= params.particleCount) {
                return;
            }
            outputPosition = interaction_read_particle(
                particleIndex,
                canonicalParticles,
                scratchParticles,
                params.neighborReadMode
            ).position.xyz;
        }

        lineVertices[id].position = outputPosition;
    }
    """

    static func rebuildInteractionPlan(particleCount: Int) -> OptimizationInteractionPlanData {
        let safeParticleCount = max(1, particleCount)
        let groupIndices = Array(repeating: UInt32(0), count: safeParticleCount)
        let indices = (0..<safeParticleCount).map(UInt32.init)
        let rangeOffsets: [UInt32] = [0, 1]
        let rangeTargets: [UInt32] = [0]
        let ranges = [
            InteractionRangeEntry(
                startIndex: 0,
                count: UInt32(safeParticleCount)
            )
        ]

        return OptimizationInteractionPlanData(
            groupIndices: groupIndices,
            rangeOffsets: rangeOffsets,
            rangeTargets: rangeTargets,
            ranges: ranges,
            indices: indices
        )
    }
}
