import Foundation
import simd

struct FixedGridOptimizationSettings: Equatable, Sendable {
    var subdivisions: Int
    var subspaceCap: Int
    var neighborReadMode: FixedGridNeighborReadMode = .scratch

    var clampedSubdivisions: Int {
        min(max(1, subdivisions), FixedGridOptimizationModuleRuntime.maxSubdivisions)
    }

    var clampedSubspaceCap: Int {
        min(max(1, subspaceCap), clampedSubdivisions)
    }
}

struct FixedGridInteractionTopology: Equatable, Sendable {
    var settings: FixedGridOptimizationSettings
    var rangeOffsets: [UInt32]
    var rangeTargets: [UInt32]
}

enum FixedGridOptimizationModuleRuntime {
    static let moduleName = "Fixed Grid Optimization Module"
    static let defaultSubdivisions = 8
    static let maxSubdivisions = 64
    static let computeShaderSource = """
    struct FixedGridAssignParticlesParams {
        uint particleCount;
        uint subdivisions;
        uint neighborReadMode;
        uint _padding1;
    };

    struct FixedGridCellCountParams {
        uint cellCount;
        uint _padding0;
        uint _padding1;
        uint _padding2;
    };

    struct FixedGridScanStepParams {
        uint cellCount;
        uint stride;
        uint _padding0;
        uint _padding1;
    };

    inline uint fixed_grid_cell_coordinate(float positionAxis, uint subdivisions) {
        if (subdivisions <= 1) {
            return 0;
        }
        float normalized = clamp((positionAxis + 1.0f) * 0.5f, 0.0f, 0.99999994f);
        return min(subdivisions - 1, uint(normalized * float(subdivisions)));
    }

    inline uint fixed_grid_linear_cell_index(float4 position, uint subdivisions) {
        uint x = fixed_grid_cell_coordinate(position.x, subdivisions);
        uint y = fixed_grid_cell_coordinate(position.y, subdivisions);
        uint z = fixed_grid_cell_coordinate(position.z, subdivisions);
        return x + y * subdivisions + z * subdivisions * subdivisions;
    }

    kernel void fixed_grid_clear_cell_counts(
        device atomic_uint *cellCounts [[buffer(0)]],
        constant FixedGridCellCountParams& params [[buffer(1)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id >= params.cellCount) {
            return;
        }
        atomic_store_explicit(&cellCounts[id], 0u, memory_order_relaxed);
    }

    kernel void fixed_grid_assign_particles_to_groups(
        device const ParticleState *particles [[buffer(0)]],
        device uint *groupIndices [[buffer(1)]],
        device atomic_uint *cellCounts [[buffer(2)]],
        constant FixedGridAssignParticlesParams& params [[buffer(3)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id >= params.particleCount) {
            return;
        }

        ParticleState particle = particles[id];
        if (particle_active(particle) == 0) {
            groupIndices[id] = 0;
            return;
        }

        uint cellIndex = fixed_grid_linear_cell_index(particle.position, params.subdivisions);
        groupIndices[id] = cellIndex;
        atomic_fetch_add_explicit(&cellCounts[cellIndex], 1u, memory_order_relaxed);
    }

    kernel void fixed_grid_build_group_ranges(
        device const atomic_uint *cellCounts [[buffer(0)]],
        device uint *scanBuffer [[buffer(1)]],
        constant FixedGridCellCountParams& params [[buffer(2)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id >= params.cellCount) {
            return;
        }

        scanBuffer[id] = atomic_load_explicit(&cellCounts[id], memory_order_relaxed);
    }

    kernel void fixed_grid_scan_group_ranges(
        device const uint *inputScanBuffer [[buffer(0)]],
        device uint *outputScanBuffer [[buffer(1)]],
        constant FixedGridScanStepParams& params [[buffer(2)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id >= params.cellCount) {
            return;
        }

        uint value = inputScanBuffer[id];
        if (id >= params.stride) {
            value += inputScanBuffer[id - params.stride];
        }
        outputScanBuffer[id] = value;
    }

    kernel void fixed_grid_finalize_group_ranges(
        device const atomic_uint *cellCounts [[buffer(0)]],
        device const uint *inclusiveScanBuffer [[buffer(1)]],
        device uint *cellOffsets [[buffer(2)]],
        device atomic_uint *cellWriteHeads [[buffer(3)]],
        device InteractionRangeEntry *interactionRanges [[buffer(4)]],
        constant FixedGridCellCountParams& params [[buffer(5)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id > params.cellCount) {
            return;
        }

        if (id == 0) {
            cellOffsets[0] = 0;
        }
        if (id == params.cellCount) {
            return;
        }

        uint count = atomic_load_explicit(&cellCounts[id], memory_order_relaxed);
        uint startIndex = (id == 0) ? 0u : inclusiveScanBuffer[id - 1];
        uint endIndex = inclusiveScanBuffer[id];
        interactionRanges[id].startIndex = startIndex;
        interactionRanges[id].count = count;
        atomic_store_explicit(&cellWriteHeads[id], startIndex, memory_order_relaxed);
        cellOffsets[id + 1] = endIndex;
    }

    kernel void fixed_grid_scatter_particle_indices(
        device const ParticleState *particles [[buffer(0)]],
        device const uint *groupIndices [[buffer(1)]],
        device atomic_uint *cellWriteHeads [[buffer(2)]],
        device uint *interactionIndices [[buffer(3)]],
        device ParticleState *scratchParticles [[buffer(4)]],
        device uint *scratchToCanonical [[buffer(5)]],
        constant FixedGridAssignParticlesParams& params [[buffer(6)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id >= params.particleCount) {
            return;
        }

        ParticleState particle = particles[id];
        if (particle_active(particle) == 0) {
            return;
        }

        uint cellIndex = groupIndices[id];
        uint writeIndex = atomic_fetch_add_explicit(&cellWriteHeads[cellIndex], 1u, memory_order_relaxed);
        if (params.neighborReadMode == interaction_neighbor_read_mode_scratch) {
            scratchParticles[writeIndex] = particle;
            scratchToCanonical[writeIndex] = id;
            interactionIndices[writeIndex] = writeIndex;
        } else {
            interactionIndices[writeIndex] = id;
        }
    }
    """

    static func buildInteractionTopology(
        settings: FixedGridOptimizationSettings
    ) -> FixedGridInteractionTopology {
        let subdivisions = settings.clampedSubdivisions
        let subspaceCap = min(settings.clampedSubspaceCap, subdivisions)
        let totalCellCount = subdivisions * subdivisions * subdivisions
        let relativeOffsets = wrappedNeighborhoodOffsets(
            subspaceCap: subspaceCap,
            subdivisions: subdivisions
        )

        var rangeOffsets = Array(repeating: UInt32(0), count: totalCellCount + 1)
        var rangeTargets: [UInt32] = []
        rangeTargets.reserveCapacity(totalCellCount * relativeOffsets.count)

        for cellIndex in 0..<totalCellCount {
            rangeOffsets[cellIndex] = UInt32(rangeTargets.count)
            let sourceCoordinates = decodeCellIndex(cellIndex, subdivisions: subdivisions)

            for offset in relativeOffsets {
                let targetX = wrappedCellCoordinate(sourceCoordinates.x + offset.x, subdivisions: subdivisions)
                let targetY = wrappedCellCoordinate(sourceCoordinates.y + offset.y, subdivisions: subdivisions)
                let targetZ = wrappedCellCoordinate(sourceCoordinates.z + offset.z, subdivisions: subdivisions)
                let targetCellIndex = linearCellIndex(
                    x: targetX,
                    y: targetY,
                    z: targetZ,
                    subdivisions: subdivisions
                )
                rangeTargets.append(UInt32(targetCellIndex))
            }
        }
        rangeOffsets[totalCellCount] = UInt32(rangeTargets.count)

        return FixedGridInteractionTopology(
            settings: FixedGridOptimizationSettings(
                subdivisions: subdivisions,
                subspaceCap: subspaceCap,
                neighborReadMode: settings.neighborReadMode
            ),
            rangeOffsets: rangeOffsets,
            rangeTargets: rangeTargets
        )
    }

    static func projectedTopologyBytes(
        settings: FixedGridOptimizationSettings
    ) -> UInt64 {
        let subdivisions = settings.clampedSubdivisions
        let subspaceCap = min(settings.clampedSubspaceCap, subdivisions)
        let totalCellCount = max(1, subdivisions * subdivisions * subdivisions)
        let neighborCount = max(
            1,
            wrappedNeighborhoodOffsets(
                subspaceCap: subspaceCap,
                subdivisions: subdivisions
            ).count
        )

        let rangeOffsetsBytes = UInt64(totalCellCount + 1) * UInt64(MemoryLayout<UInt32>.stride)
        let rangeTargetsBytes = UInt64(totalCellCount * neighborCount) * UInt64(MemoryLayout<UInt32>.stride)
        let dynamicRangesBytes = UInt64(totalCellCount) * UInt64(MemoryLayout<InteractionRangeEntry>.stride)
        let plannerScratchBytes =
            UInt64(totalCellCount) * UInt64(MemoryLayout<UInt32>.stride) * 4

        return rangeOffsetsBytes + rangeTargetsBytes + dynamicRangesBytes + plannerScratchBytes
    }

    static func projectedScratchBytes(particleCount: Int) -> UInt64 {
        let slotCount = max(1, particleCount)
        let particleBytes = UInt64(slotCount) * UInt64(MemoryLayout<ParticleState>.stride)
        let reverseMapBytes = UInt64(slotCount) * UInt64(MemoryLayout<UInt32>.stride)
        return particleBytes + reverseMapBytes
    }

    static func cellIndex(
        for position: SIMD4<Float>,
        settings: FixedGridOptimizationSettings
    ) -> Int {
        linearCellIndex(
            for: position,
            subdivisions: settings.clampedSubdivisions
        )
    }

    private static func neighborhoodOffsets(subspaceCap: Int) -> [SIMD3<Int>] {
        if subspaceCap <= 1 {
            return [SIMD3<Int>(0, 0, 0)]
        }

        var offsets: [SIMD3<Int>] = []
        for expansionDistance in 0...(subspaceCap - 2) {
            let axisLimit = expansionDistance + 1
            for z in -axisLimit...axisLimit {
                for y in -axisLimit...axisLimit {
                    for x in -axisLimit...axisLimit {
                        let layerDistance =
                            max(abs(x) - 1, 0)
                            + max(abs(y) - 1, 0)
                            + max(abs(z) - 1, 0)
                        guard layerDistance == expansionDistance else { continue }
                        offsets.append(SIMD3<Int>(x, y, z))
                    }
                }
            }
        }
        return offsets
    }

    private static func wrappedNeighborhoodOffsets(
        subspaceCap: Int,
        subdivisions: Int
    ) -> [SIMD3<Int>] {
        let relativeOffsets = neighborhoodOffsets(subspaceCap: subspaceCap)
        var uniqueOffsets: [SIMD3<Int>] = []
        uniqueOffsets.reserveCapacity(relativeOffsets.count)
        var seenOffsets = Set<Int>()
        seenOffsets.reserveCapacity(relativeOffsets.count)

        for offset in relativeOffsets {
            let wrappedX = wrappedCellCoordinate(offset.x, subdivisions: subdivisions)
            let wrappedY = wrappedCellCoordinate(offset.y, subdivisions: subdivisions)
            let wrappedZ = wrappedCellCoordinate(offset.z, subdivisions: subdivisions)
            let packed = wrappedX
                + wrappedY * subdivisions
                + wrappedZ * subdivisions * subdivisions
            guard seenOffsets.insert(packed).inserted else { continue }
            uniqueOffsets.append(SIMD3<Int>(wrappedX, wrappedY, wrappedZ))
        }

        return uniqueOffsets
    }

    private static func linearCellIndex(for position: SIMD4<Float>, subdivisions: Int) -> Int {
        linearCellIndex(
            x: cellCoordinate(for: position.x, subdivisions: subdivisions),
            y: cellCoordinate(for: position.y, subdivisions: subdivisions),
            z: cellCoordinate(for: position.z, subdivisions: subdivisions),
            subdivisions: subdivisions
        )
    }

    private static func linearCellIndex(x: Int, y: Int, z: Int, subdivisions: Int) -> Int {
        x + y * subdivisions + z * subdivisions * subdivisions
    }

    private static func decodeCellIndex(_ cellIndex: Int, subdivisions: Int) -> SIMD3<Int> {
        let z = cellIndex / (subdivisions * subdivisions)
        let y = (cellIndex / subdivisions) % subdivisions
        let x = cellIndex % subdivisions
        return SIMD3<Int>(x, y, z)
    }

    private static func cellCoordinate(for positionAxis: Float, subdivisions: Int) -> Int {
        guard subdivisions > 1 else { return 0 }
        let normalized = min(max((positionAxis + 1) * 0.5, 0), 0.99999994)
        return min(subdivisions - 1, Int(normalized * Float(subdivisions)))
    }

    private static func wrappedCellCoordinate(_ value: Int, subdivisions: Int) -> Int {
        let remainder = value % subdivisions
        return remainder >= 0 ? remainder : remainder + subdivisions
    }
}
