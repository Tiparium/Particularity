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
        uint firstTargetIndex;
        uint interactionCount;
        uint particleCount;
        uint active;
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
        uint id [[thread_position_in_grid]]
    ) {
        uint vertexCount = params.interactionCount * 2;
        if (id >= vertexCount) {
            return;
        }

        if (params.active == 0) {
            lineVertices[id].position = float3(0.0);
            return;
        }

        uint interactionIndex = id / 2;
        uint particleIndex = (id % 2 == 0) ? 0 : min(params.firstTargetIndex + interactionIndex, params.particleCount - 1);
        lineVertices[id].position = positions[particleIndex].xyz;
    }
    """
    static func pointSize(for state: SimulationViewportState) -> Float {
        max(3.0, state.sphereSize * 480.0)
    }

    static func chunkPairCount(for particleCount: Int) -> UInt64 {
        guard particleCount > 0 else { return 0 }
        let totalPairs = UInt64(particleCount) * UInt64(particleCount)
        let suggested = max(UInt64(1_048_576), min(UInt64(8_388_608), totalPairs / 32))
        return min(totalPairs, suggested)
    }
}
