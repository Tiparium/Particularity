import Metal
import Testing
@testable import Particularity

@Suite("Metal shader compilation")
struct MetalShaderCompilationTests {
    @Test("compiles shared runtime shader library")
    func compilesSharedRuntimeShaderLibrary() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }

        let source = [
            SimulationMetalSharedSource.source,
            DefaultVisualModuleRuntime.shaderSource,
            MLTrainingPlaybackPresenterRuntime.shaderSource,
            ProfileHeaderPlaybackPresenterRuntime.shaderSource,
            try PhysicsShaderSourceFiles.defaultPhysicsSource(),
            try PhysicsShaderSourceFiles.packagedPhysicsSources().joined(separator: "\n\n"),
            DefaultOptimizationModuleRuntime.computeShaderSource,
            FixedGridOptimizationModuleRuntime.computeShaderSource,
        ].joined(separator: "\n\n")

        let library = try device.makeLibrary(source: source, options: nil)
        #expect(library.makeFunction(name: "ml_playback_surface_mesh_vs") != nil)
        #expect(library.makeFunction(name: "ml_playback_surface_mesh_fs") != nil)
        #expect(library.makeFunction(name: "ml_playback_surface_mesh_smooth") != nil)
        #expect(library.makeFunction(name: "profile_header_particle_vs") != nil)
        #expect(library.makeFunction(name: "profile_header_particle_fs") != nil)
        #expect(library.makeFunction(name: "profile_header_vert_vs") != nil)
        #expect(library.makeFunction(name: "profile_header_vert_fs") != nil)
    }
}
