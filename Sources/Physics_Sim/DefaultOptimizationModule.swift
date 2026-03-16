import Foundation

enum DefaultOptimizationModuleRuntime {
    static let computeShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct OptimizationChunkParams {
        ulong startPair;
        ulong pairCount;
        uint particleCount;
        uint threadCount;
    };

    struct OptimizationScratchState {
        atomic_uint checksum;
    };

    struct OptimizationDebugLineParams {
        uint particleCount;
        uint segmentCount;
    };

    struct OptimizationDebugLineSegment {
        uint firstTargetIndex;
        uint interactionCount;
        uint firstVertexIndex;
        uint _padding;
    };

    struct OptimizationLineVertex {
        float3 position;
    };

    kernel void optimization_chunk(
        device const float4 *positions [[buffer(0)]],
        constant OptimizationChunkParams& params [[buffer(1)]],
        device OptimizationScratchState *scratch [[buffer(2)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id >= params.threadCount) {
            return;
        }

        uint localChecksum = 0;
        for (ulong offset = id; offset < params.pairCount; offset += params.threadCount) {
            ulong pairIndex = params.startPair + offset;
            uint sourceIndex = uint(pairIndex % ulong(params.particleCount));
            uint targetIndex = uint(pairIndex / ulong(params.particleCount));
            float4 sourcePosition = positions[sourceIndex];
            float4 targetPosition = positions[targetIndex];
            localChecksum ^= as_type<uint>(sourcePosition.x) ^ as_type<uint>(targetPosition.y);
        }

        atomic_fetch_xor_explicit(&scratch->checksum, localChecksum, memory_order_relaxed);
    }

    kernel void build_debug_lines(
        device const float4 *positions [[buffer(0)]],
        device OptimizationLineVertex *lineVertices [[buffer(1)]],
        constant OptimizationDebugLineParams& params [[buffer(2)]],
        device const OptimizationDebugLineSegment *segments [[buffer(3)]],
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

        if (!found) {
            return;
        }

        uint localVertexIndex = id - segment.firstVertexIndex;
        uint interactionIndex = localVertexIndex / 2;
        uint particleIndex = (localVertexIndex % 2 == 0) ? 0 : min(segment.firstTargetIndex + interactionIndex, params.particleCount - 1);
        lineVertices[id].position = positions[particleIndex].xyz;
    }
    """
    static func pointSize(for state: SimulationViewportState) -> Float {
        max(3.0, state.sphereSize * 480.0)
    }
}
