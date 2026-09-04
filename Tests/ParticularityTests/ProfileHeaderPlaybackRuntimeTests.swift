import Testing
import simd
@testable import Particularity

@Suite("Profile header playback runtime")
struct ProfileHeaderPlaybackRuntimeTests {
    @Test("vert thickness variance remains normalized")
    func vertThicknessVarianceRemainsNormalized() {
        for sourceIndex in stride(from: 0, through: 8_000, by: 97) {
            let sample = ProfileHeaderVertGeometry.varianceSample(
                sourceIndex: sourceIndex,
                targetIndex: sourceIndex + 47
            )
            #expect(sample >= 0)
            #expect(sample <= 1)
        }
    }

    @Test("connects only nearby glyph nodes")
    func connectsOnlyNearbyGlyphNodes() {
        let runtime = ProfileHeaderPlaybackRuntime(
            text: "Nainoa Faulkner-Jackson",
            nodeCount: 1_200,
            motionRadius: 0,
            durationSeconds: 15
        )
        let particles = runtime.frame(at: 0).particles
        let connections = runtime.connectionPairs(coverage: 1, maxConnections: 2)

        #expect(!connections.isEmpty)
        #expect(connections.allSatisfy { connection in
            simd_distance(
                particles[connection.source].position,
                particles[connection.target].position
            ) < 0.075
        })
    }

    @Test("honors requested node count")
    func honorsRequestedNodeCount() {
        let runtime = ProfileHeaderPlaybackRuntime(
            text: "Nainoa Faulkner-Jackson",
            nodeCount: 1_200,
            motionRadius: 0.018,
            durationSeconds: 15
        )

        #expect(runtime.frame(at: 0).particles.count == 1_200)
    }

    @Test("closes its deterministic loop")
    func closesDeterministicLoop() {
        let runtime = ProfileHeaderPlaybackRuntime(
            text: "Nainoa",
            nodeCount: 600,
            motionRadius: 0.018,
            durationSeconds: 15
        )

        let start = runtime.frame(at: 0).particles
        let end = runtime.frame(at: 15).particles

        #expect(start.count == end.count)
        #expect(zip(start, end).allSatisfy { $0.position == $1.position })
    }
}
