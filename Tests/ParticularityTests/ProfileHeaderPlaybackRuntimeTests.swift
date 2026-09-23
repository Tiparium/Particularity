import Testing
import simd
@testable import Particularity

@Suite("Profile header playback runtime")
struct ProfileHeaderPlaybackRuntimeTests {
    @Test("export frame preparation advances vert geometry with the nodes")
    @MainActor
    func exportPreparationAdvancesVertGeometry() async throws {
        let session = try await SimulationSession.create()
        let modules = ActiveModuleSet(
            physics: try #require(ModuleCatalog.knownModulesByName["ProfileHeaderPlaybackProcessor"]),
            visual: try #require(ModuleCatalog.knownModulesByName["ProfileHeaderPlaybackPresenter"]),
            optimization: try #require(ModuleCatalog.knownModulesByName["ProfileHeaderPlaybackReader"])
        )
        try session.updateActiveModules(modules)

        var state = session.simulationState
        state.profileHeader.isActive = true
        session.updateSimulationState(state)

        #expect(session.preparePlaybackFrameForExport(at: 0))
        let startVertex = firstPresentationVertex(in: session)
        #expect(session.preparePlaybackFrameForExport(at: 3.75))
        let advancedVertex = firstPresentationVertex(in: session)

        #expect(startVertex != nil)
        #expect(advancedVertex != nil)
        #expect(startVertex != advancedVertex)
    }

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

    @Test("lays out newline-separated text as centered independent lines")
    func laysOutMultilineText() throws {
        let runtime = ProfileHeaderPlaybackRuntime(
            text: "AA\nBB",
            nodesPerCharacter: 200,
            textScale: 0.5,
            motionRadius: 0,
            durationSeconds: 15
        )
        let particles = runtime.frame(at: 0).particles
        let groupedPositions = Dictionary(grouping: particles.indices) {
            runtime.glyphOwner(ofNodeAt: $0)
        }

        #expect(particles.count == 800)
        #expect(groupedPositions.keys.compactMap { $0 }.count == 4)
        let firstLineMean = try meanZ(forOwners: [0, 1], groups: groupedPositions, particles: particles)
        let secondLineMean = try meanZ(forOwners: [2, 3], groups: groupedPositions, particles: particles)
        #expect(abs(firstLineMean - secondLineMean) > 0.15)
    }

    @Test("aligns multiline text against shared left, center, and right edges")
    func alignsMultilineText() throws {
        for alignment in [
            ProfileHeaderTextAlignment.left,
            .center,
            .right,
        ] {
            let runtime = ProfileHeaderPlaybackRuntime(
                text: "I\nMMMM",
                textAlignment: alignment,
                nodesPerCharacter: 150,
                textScale: 0.5,
                motionRadius: 0,
                durationSeconds: 15
            )
            let particles = runtime.frame(at: 0).particles
            let firstLine = particles.indices.filter { runtime.glyphOwner(ofNodeAt: $0) == 0 }
            let secondLine = particles.indices.filter { (runtime.glyphOwner(ofNodeAt: $0) ?? 0) > 0 }
            let firstBounds = try horizontalBounds(for: firstLine, particles: particles)
            let secondBounds = try horizontalBounds(for: secondLine, particles: particles)

            switch alignment {
            case .left:
                #expect(abs(firstBounds.lowerBound - secondBounds.lowerBound) < 0.04)
            case .center:
                #expect(abs(firstBounds.midpoint - secondBounds.midpoint) < 0.04)
            case .right:
                #expect(abs(firstBounds.upperBound - secondBounds.upperBound) < 0.04)
            }
        }
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

    @MainActor
    private func firstPresentationVertex(in session: SimulationSession) -> SIMD4<Float>? {
        let renderState = session.renderState
        guard renderState.presentationLineVertexCount > 0,
              let buffer = renderState.presentationLineBuffer else {
            return nil
        }
        return buffer.contents()
            .bindMemory(to: ProfileHeaderVertVertex.self, capacity: 1)
            .pointee.position
    }

    private func meanZ(
        forOwners owners: [Int],
        groups: [Int?: [Int]],
        particles: [ParticleState]
    ) throws -> Float {
        let indices = owners.flatMap { groups[$0] ?? [] }
        let populatedIndices = try #require(indices.isEmpty ? nil : indices)
        return populatedIndices.reduce(0) { $0 + particles[$1].position.z } / Float(populatedIndices.count)
    }

    private func horizontalBounds(
        for indices: [Int],
        particles: [ParticleState]
    ) throws -> ClosedRange<Float> {
        let populatedIndices = try #require(indices.isEmpty ? nil : indices)
        let values = populatedIndices.map { particles[$0].position.x }
        let minimum = try #require(values.min())
        let maximum = try #require(values.max())
        return minimum...maximum
    }
}

private extension ClosedRange where Bound == Float {
    var midpoint: Float { (lowerBound + upperBound) * 0.5 }
}
