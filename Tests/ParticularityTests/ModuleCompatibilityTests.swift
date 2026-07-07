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
            visual: ModuleCatalog.knownModulesByName["DefaultGreySpheres"]!,
            optimization: ModuleCatalog.defaultOptimization
        )
        var state = viewportState()
        state.showOptimizationInfo = true

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: state)?.contains("does not accept optimization debug data") == true)
    }

    @Test("accepts custom realtime physics processors with standard entry points")
    func acceptsCustomRealtimePhysicsProcessorWithStandardEntryPoints() {
        let modules = ActiveModuleSet(
            physics: descriptor(
                kind: .physics,
                name: "Custom Processor",
                executionModel: .realtime,
                pipelineStage: .processor,
                entryPoints: ModuleEntryPoints(update: ["custom_accumulate"], postUpdate: ["custom_apply"])
            ),
            visual: ModuleCatalog.defaultVisual,
            optimization: ModuleCatalog.defaultOptimization
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState()) == nil)
    }

    @Test("rejects custom physics processors without standard entry points")
    func rejectsCustomPhysicsProcessorWithoutStandardEntryPoints() {
        let modules = ActiveModuleSet(
            physics: descriptor(kind: .physics, name: "Missing Entry Points", executionModel: .realtime, pipelineStage: .processor),
            visual: ModuleCatalog.defaultVisual,
            optimization: ModuleCatalog.defaultOptimization
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState())?.contains("must declare update and postUpdate") == true)
    }

    @Test("rejects manifest driven presenters until presenter execution is supported")
    func rejectsManifestDrivenPresenterExecution() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.defaultPhysics,
            visual: descriptor(kind: .visual, name: "Custom Presenter", executionModel: .realtime, pipelineStage: .presenter),
            optimization: ModuleCatalog.defaultOptimization
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState())?.contains("does not yet support manifest-driven visual execution") == true)
    }

    @Test("accepts known toy playback trio")
    func acceptsKnownToyPlaybackTrio() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.knownModulesByName["ToyPlaybackProcessor"]!,
            visual: ModuleCatalog.knownModulesByName["ToyPlaybackPresenter"]!,
            optimization: ModuleCatalog.knownModulesByName["ToyPlaybackReader"]!
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState()) == nil)
    }

    @Test("rejects playback trio with incompatible contracts")
    func rejectsPlaybackTrioWithIncompatibleContracts() {
        let modules = ActiveModuleSet(
            physics: descriptor(
                kind: .physics,
                name: "ToyPlaybackProcessor",
                executionModel: .playback,
                pipelineStage: .processor,
                moduleFamilyID: "playback-demo",
                consumesContracts: ["other.input"],
                producesContracts: ["demo.output"]
            ),
            visual: descriptor(
                kind: .visual,
                name: "ToyPlaybackPresenter",
                executionModel: .playback,
                pipelineStage: .presenter,
                moduleFamilyID: "playback-demo",
                consumesContracts: ["demo.output"]
            ),
            optimization: descriptor(
                kind: .optimization,
                name: "ToyPlaybackReader",
                executionModel: .playback,
                pipelineStage: .producer,
                moduleFamilyID: "playback-demo",
                producesContracts: ["demo.input"]
            )
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState())?.contains("does not consume") == true)
    }

    @Test("decodes required module manifest IDs and entry point arrays")
    func decodesModuleManifestEntryPoints() throws {
        let json = """
        {
          "id": "example.realtime.processor.demo",
          "name": "Demo Processor",
          "kind": "physics",
          "version": 1,
          "moduleFamilyID": "demo.family",
          "consumesContracts": ["demo.input"],
          "producesContracts": ["demo.output"],
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
        #expect(manifest.moduleFamilyID == "demo.family")
        #expect(manifest.consumesContracts == ["demo.input"])
        #expect(manifest.producesContracts == ["demo.output"])
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

    @Test("persists fixed grid optimization settings in the main editor snapshot")
    func persistsFixedGridOptimizationSettings() throws {
        var editorState = SimulationEditorState()
        editorState.optimizationState = OptimizationModuleState(
            showLeaderCommunicationLog: true,
            fixedGridSubdivisions: 9,
            fixedGridSubspaceCap: 4,
            fixedGridNeighborReadMode: .raw
        )

        let encoded = try JSONEncoder().encode(MainWindowSimulationStateSnapshot.from(editorState: editorState))
        let decoded = try JSONDecoder().decode(MainWindowSimulationStateSnapshot.self, from: encoded)

        #expect(decoded.editorState.optimizationState.showLeaderCommunicationLog == true)
        #expect(decoded.editorState.optimizationState.fixedGridSubdivisions == 9)
        #expect(decoded.editorState.optimizationState.fixedGridSubspaceCap == 4)
        #expect(decoded.editorState.optimizationState.fixedGridNeighborReadMode == .raw)
    }

    @Test("resolved configuration validates against the selected optimization module")
    func resolvedConfigurationUsesSelectedOptimizationForValidation() {
        var editorState = SimulationEditorState()
        editorState.physicsState.particleCount = DefaultOptimizationModuleRuntime.particleCountCap + 1
        editorState.assignedModuleIDs[ModuleKind.optimization.rawValue] = "particularity.realtime.producer.fixed_grid"

        let configuration = SimulationConfigurationDerivation.resolvedRuntimeConfiguration(
            editorState: editorState,
            transportState: .stopped,
            availableBundles: [
                moduleBundle(
                    id: "particularity.realtime.producer.fixed_grid",
                    kind: .optimization,
                    descriptor: ModuleCatalog.knownModulesByName[FixedGridOptimizationModuleRuntime.moduleName]!
                )
            ]
        )

        #expect(configuration.activeModules.optimization.name == FixedGridOptimizationModuleRuntime.moduleName)
        #expect(configuration.validationReport.issue(for: .particleCount) == nil)
    }

    private func descriptor(
        kind: ModuleKind,
        name: String,
        executionModel: ModuleExecutionModel,
        pipelineStage: ModulePipelineStage,
        moduleFamilyID: String? = nil,
        consumesContracts: [String] = [],
        producesContracts: [String] = [],
        entryPoints: ModuleEntryPoints = ModuleEntryPoints()
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            kind: kind.rawValue,
            name: name,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: moduleFamilyID,
            consumesContracts: consumesContracts,
            producesContracts: producesContracts,
            executionModel: executionModel,
            pipelineStage: pipelineStage,
            entryPoints: entryPoints
        )
    }

    private func moduleBundle(
        id: String,
        kind: ModuleKind,
        descriptor: ModuleDescriptor
    ) -> ModuleBundle {
        let url = URL(fileURLWithPath: "/tmp/\(id)/module.json")
        return ModuleBundle(
            id: id,
            kind: kind,
            manifestURL: url,
            bundleURL: url.deletingLastPathComponent(),
            descriptor: descriptor,
            manifest: nil
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
            playbackRate: 1,
            playbackLooping: true,
            fixedGridSubdivisions: 1,
            fixedGridSubspaceCap: 1,
            fixedGridNeighborReadMode: .scratch
        )
    }
}
