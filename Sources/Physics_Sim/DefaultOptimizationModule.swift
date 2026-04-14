import Foundation

enum DefaultOptimizationModuleRuntime {
    enum InteractionPlanError: LocalizedError {
        case particleCountExceedsCap(Int, Int)

        var errorDescription: String? {
            switch self {
            case .particleCountExceedsCap(let count, let cap):
                return "\(ModuleCatalog.defaultOptimization.name) supports at most \(cap.formatted()) particles. Current particle count is \(count.formatted())."
            }
        }
    }

    static let particleCountCap = 65_535

    enum InteractionTraversalMode: UInt32 {
        case explicitIndices = 0
        case canonicalRange = 1
    }

    struct InteractionPlanData {
        var traversalMode: InteractionTraversalMode
        var offsets: [UInt32]
        var indices: [UInt32]
    }

    static let computeShaderSource = """
    struct OptimizationDebugLineParams {
        uint segmentCount;
        uint particleCount;
        uint traversalMode;
        uint _padding0;
    };

    struct OptimizationDebugLineSegment {
        uint sourceParticleIndex;
        uint interactionOffset;
        uint interactionCount;
        uint firstVertexIndex;
    };

    struct OptimizationLineVertex {
        float3 position;
    };

    kernel void build_debug_lines(
        device const ParticleState *particles [[buffer(0)]],
        device const uint *interactionIndices [[buffer(1)]],
        device OptimizationLineVertex *lineVertices [[buffer(2)]],
        constant OptimizationDebugLineParams& params [[buffer(3)]],
        device const OptimizationDebugLineSegment *segments [[buffer(4)]],
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
        if ((localVertexIndex % 2) != 0) {
            if (params.traversalMode == 1) {
                particleIndex = min(interactionIndex, params.particleCount - 1);
            } else {
                particleIndex = interactionIndices[segment.interactionOffset + interactionIndex];
            }
        }

        lineVertices[id].position = particles[particleIndex].position.xyz;
    }
    """

    static func rebuildInteractionPlan(particleCount: Int) throws -> InteractionPlanData {
        let safeParticleCount = max(1, particleCount)
        guard safeParticleCount <= particleCountCap else {
            throw InteractionPlanError.particleCountExceedsCap(safeParticleCount, particleCountCap)
        }

        var offsets: [UInt32] = []
        offsets.reserveCapacity(safeParticleCount + 1)
        for index in 0...safeParticleCount {
            offsets.append(UInt32(index * safeParticleCount))
        }

        return InteractionPlanData(
            traversalMode: .canonicalRange,
            offsets: offsets,
            indices: []
        )
    }

    static func validationIssues(
        activeModules: ActiveModuleSet,
        editorState: SimulationEditorState
    ) -> [RuntimeValidationIssue] {
        guard activeModules.optimization.name == ModuleCatalog.defaultOptimization.name else {
            return []
        }

        let particleCount = editorState.physicsState.particleCount
        guard particleCount > particleCountCap else { return [] }
        return [
            RuntimeValidationIssue(
                field: .particleCount,
                message: "\(ModuleCatalog.defaultOptimization.name) supports at most \(particleCountCap.formatted()) particles. Current particle count is \(particleCount.formatted())."
            )
        ]
    }
}
