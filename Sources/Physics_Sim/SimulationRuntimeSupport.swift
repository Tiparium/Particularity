import Foundation
import Darwin.Mach
import Metal

struct SimulationMetricsAccumulator {
    private(set) var physicsStepSamples: [(time: TimeInterval, count: Int)] = []
    private(set) var leaderInteractionSamples: [(time: TimeInterval, count: Int)] = []
    private(set) var lastPublishTime: TimeInterval = 0

    let sampleWindowSeconds: TimeInterval
    let publishInterval: TimeInterval

    mutating func reset() {
        physicsStepSamples.removeAll(keepingCapacity: false)
        leaderInteractionSamples.removeAll(keepingCapacity: false)
        lastPublishTime = 0
    }

    mutating func recordPhysicsStep(at now: TimeInterval) {
        physicsStepSamples.append((time: now, count: 1))
    }

    mutating func recordLeaderInteractions(_ count: Int, at now: TimeInterval) {
        guard count > 0 else { return }
        leaderInteractionSamples.append((time: now, count: count))
    }

    mutating func metricsIfDue(averageFPS: Double, now: TimeInterval) -> SimulationPerformanceMetrics? {
        guard now - lastPublishTime >= publishInterval else { return nil }
        lastPublishTime = now

        let cutoff = now - sampleWindowSeconds
        physicsStepSamples.removeAll { $0.time < cutoff }
        leaderInteractionSamples.removeAll { $0.time < cutoff }

        return SimulationPerformanceMetrics(
            memoryUsedBytes: currentProcessResidentMemoryBytes(),
            averageFPS: averageFPS,
            averageUPS: ratePerSecond(for: physicsStepSamples),
            leaderInteractionsPerSecond: ratePerSecond(for: leaderInteractionSamples),
            sampleWindowSeconds: sampleWindowSeconds
        )
    }

    private func ratePerSecond(for samples: [(time: TimeInterval, count: Int)]) -> Double {
        let totalCount = samples.reduce(0) { $0 + $1.count }
        guard let first = samples.first?.time, let last = samples.last?.time, last > first else {
            return samples.isEmpty ? 0 : Double(totalCount) / sampleWindowSeconds
        }
        return Double(totalCount) / max(last - first, 0.001)
    }

    private func currentProcessResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}

struct SimulationDebugHistory {
    private struct CachedLeaderSweepSegment {
        var firstTargetIndex: Int
        var interactionCount: Int
        var startedAt: TimeInterval
    }

    private(set) var renderSegments: [SimulationDebugRenderSegment] = []
    private var cachedSegments: [CachedLeaderSweepSegment] = []

    let historyCapacity: Int
    let visibilityDuration: TimeInterval

    init(historyCapacity: Int, visibilityDuration: TimeInterval) {
        self.historyCapacity = historyCapacity
        self.visibilityDuration = visibilityDuration
    }

    mutating func reset() {
        renderSegments.removeAll(keepingCapacity: false)
        cachedSegments.removeAll(keepingCapacity: false)
    }

    mutating func cacheSegment(firstTargetIndex: Int, interactionCount: Int, startedAt: TimeInterval) {
        cachedSegments.append(
            CachedLeaderSweepSegment(
                firstTargetIndex: firstTargetIndex,
                interactionCount: interactionCount,
                startedAt: startedAt
            )
        )
        if cachedSegments.count > historyCapacity {
            cachedSegments.removeFirst(cachedSegments.count - historyCapacity)
        }
    }

    mutating func prune(now: TimeInterval) {
        let cutoff = now - visibilityDuration
        cachedSegments.removeAll { $0.startedAt < cutoff }
    }

    mutating func rebuildRenderSegments(
        into debugLineSegmentBuffer: MTLBuffer?
    ) {
        guard let debugLineSegmentBuffer else {
            renderSegments.removeAll(keepingCapacity: false)
            return
        }

        var nextRenderSegments: [SimulationDebugRenderSegment] = []
        var gpuSegments: [SimulationDebugLineSegment] = []
        nextRenderSegments.reserveCapacity(cachedSegments.count)
        gpuSegments.reserveCapacity(cachedSegments.count)

        var nextVertexStart = 0
        for cachedSegment in cachedSegments {
            let vertexCount = cachedSegment.interactionCount * 2
            guard vertexCount > 0 else { continue }

            nextRenderSegments.append(
                SimulationDebugRenderSegment(
                    vertexStart: nextVertexStart,
                    vertexCount: vertexCount,
                    startedAt: cachedSegment.startedAt
                )
            )
            gpuSegments.append(
                SimulationDebugLineSegment(
                    firstTargetIndex: UInt32(cachedSegment.firstTargetIndex),
                    interactionCount: UInt32(cachedSegment.interactionCount),
                    firstVertexIndex: UInt32(nextVertexStart)
                )
            )
            nextVertexStart += vertexCount
        }

        if !gpuSegments.isEmpty {
            let pointer = debugLineSegmentBuffer.contents().bindMemory(
                to: SimulationDebugLineSegment.self,
                capacity: gpuSegments.count
            )
            pointer.update(from: gpuSegments, count: gpuSegments.count)
        }

        renderSegments = nextRenderSegments
    }
}
