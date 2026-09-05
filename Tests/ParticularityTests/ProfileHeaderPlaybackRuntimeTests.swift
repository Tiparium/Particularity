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

    @Test("assigns one ownership region per rendered glyph")
    func assignsOneOwnershipRegionPerRenderedGlyph() {
        let runtime = ProfileHeaderPlaybackRuntime(
            text: "oo",
            nodesPerCharacter: 300,
            textScale: 1,
            motionRadius: 0,
            durationSeconds: 15
        )
        let particles = runtime.frame(at: 0).particles
        let owners = Set(particles.indices.compactMap(runtime.glyphOwner(ofNodeAt:)))

        #expect(owners.count == 2)
    }

    @Test("connects only nearby glyph nodes")
    func connectsOnlyNearbyGlyphNodes() {
        let runtime = ProfileHeaderPlaybackRuntime(
            text: "Nainoa Faulkner-Jackson",
            nodesPerCharacter: 60,
            textScale: 0.5,
            motionRadius: 0,
            durationSeconds: 15
        )
        let particles = runtime.frame(at: 0).particles
        let connections = runtime.connectionPairs(
            coverage: 1,
            geometryAdherence: 0.35,
            maxConnections: 2
        )

        #expect(!connections.isEmpty)
        #expect(connections.allSatisfy { connection in
            simd_distance(
                particles[connection.source].position,
                particles[connection.target].position
            ) < 0.075
        })
        let crossGlyphCount = connections.count { connection in
            runtime.glyphOwner(ofNodeAt: connection.source)
                != runtime.glyphOwner(ofNodeAt: connection.target)
        }
        #expect(Float(crossGlyphCount) / Float(connections.count) < 0.05)
    }

    @Test("derives node count from visible characters")
    func derivesNodeCountFromVisibleCharacters() {
        let runtime = ProfileHeaderPlaybackRuntime(
            text: "AB CD",
            nodesPerCharacter: 200,
            textScale: 1,
            motionRadius: 0.018,
            durationSeconds: 15
        )

        #expect(runtime.frame(at: 0).particles.count == 800)
    }

    @Test("closes its deterministic loop")
    func closesDeterministicLoop() {
        let runtime = ProfileHeaderPlaybackRuntime(
            text: "Nainoa",
            nodesPerCharacter: 100,
            textScale: 1,
            motionRadius: 0.018,
            durationSeconds: 15
        )

        let start = runtime.frame(at: 0).particles
        let end = runtime.frame(at: 15).particles

        #expect(start.count == end.count)
        #expect(zip(start, end).allSatisfy { $0.position == $1.position })
    }
}
