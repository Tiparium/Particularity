import Foundation
import Testing
@testable import Particularity

@Suite("Module compatibility")
struct ModuleCompatibilityTests {
    @Test("accepts the default realtime pipeline")
    func acceptsDefaultRealtimePipeline() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.defaultPhysics,
            visual: ModuleCatalog.defaultVisual,
            optimization: ModuleCatalog.defaultOptimization
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState()) == nil)
    }

    @Test("rejects mixed execution models")
    func rejectsMixedExecutionModels() {
        let modules = ActiveModuleSet(
            physics: descriptor(kind: .physics, name: "Playback Processor", executionModel: .playback, pipelineStage: .processor),
            visual: ModuleCatalog.defaultVisual,
            optimization: ModuleCatalog.defaultOptimization
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState())?.contains("share one execution model") == true)
    }

    @Test("rejects module in the wrong pipeline slot")
    func rejectsWrongPipelineSlot() {
        let modules = ActiveModuleSet(
            physics: descriptor(kind: .physics, name: "Wrong Stage", executionModel: .realtime, pipelineStage: .producer),
            visual: ModuleCatalog.defaultVisual,
            optimization: ModuleCatalog.defaultOptimization
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState())?.contains("requires Processor") == true)
    }

    @Test("keeps existing optimization debug validation")
    func keepsOptimizationDebugValidation() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.defaultPhysics,
            visual: descriptor(kind: .visual, name: "No Debug Visual", executionModel: .realtime, pipelineStage: .presenter),
            optimization: ModuleCatalog.defaultOptimization
        )
        var state = viewportState()
        state.showOptimizationInfo = true

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: state)?.contains("does not accept optimization debug data") == true)
    }

    @Test("decodes required module manifest IDs and entry point arrays")
    func decodesModuleManifestEntryPoints() throws {
        let json = """
        {
          "id": "example.realtime.processor.demo",
          "name": "Demo Processor",
          "kind": "physics",
          "version": 1,
          "executionModel": "realtime",
          "pipelineStage": "processor",
          "shaderSource": "module/Demo.metal",
          "entryPoints": {
            "preUpdate": "demo_clear",
            "update": ["demo_accumulate", "demo_apply"]
          }
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: json)

        #expect(manifest.id == "example.realtime.processor.demo")
        #expect(manifest.entryPoints.preUpdate == ["demo_clear"])
        #expect(manifest.entryPoints.update == ["demo_accumulate", "demo_apply"])
    }

    @Test("rejects manifests without explicit IDs")
    func rejectsManifestWithoutExplicitID() {
        let json = """
        {
          "name": "Demo Processor",
          "kind": "physics",
          "version": 1,
          "executionModel": "realtime",
          "pipelineStage": "processor"
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ModuleManifest.self, from: json)
        }
    }

    private func descriptor(
        kind: ModuleKind,
        name: String,
        executionModel: ModuleExecutionModel,
        pipelineStage: ModulePipelineStage
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            kind: kind.rawValue,
            name: name,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            executionModel: executionModel,
            pipelineStage: pipelineStage
        )
    }

    private func viewportState() -> SimulationViewportState {
        SimulationViewportState(
            transportState: .stopped,
            particleCount: 1,
            randomDistribution: true,
            particleTypes: 1,
            allParticlesIntercommunicate: true,
            movementDirection: .zero,
            timeScale: 1,
            sphereSize: 0.01,
            spectrumOffset: 0,
            showOptimizationInfo: false,
            showLeaderCommunicationLog: false,
            fixedGridSubdivisions: 1,
            fixedGridSubspaceCap: 1,
            fixedGridNeighborReadMode: .scratch
        )
    }
}
