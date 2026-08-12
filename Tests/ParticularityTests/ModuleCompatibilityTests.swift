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

    @Test("matches Primordial Soup trinity from its module trio")
    func matchesPrimordialSoupTrinity() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.knownModulesByName["TypeMatrixLocalAttractionRepulsion"]!,
            visual: ModuleCatalog.defaultVisual,
            optimization: ModuleCatalog.knownModulesByName[FixedGridOptimizationModuleRuntime.moduleName]!
        )

        let trinity = TrinityCatalog.matching(modules)

        #expect(trinity?.id == TrinityCatalog.primordialSoup.id)
        #expect(trinity?.name == "Primordial Soup v0.1")
    }

    @Test("matches Primordial Soup v0.2 trinity from its module trio")
    func matchesPrimordialSoupV02Trinity() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.knownModulesByName[PrimordialSoupLifecycleSettings.moduleName]!,
            visual: ModuleCatalog.defaultVisual,
            optimization: ModuleCatalog.knownModulesByName[FixedGridOptimizationModuleRuntime.moduleName]!
        )

        let trinity = TrinityCatalog.matching(modules)

        #expect(trinity?.id == TrinityCatalog.primordialSoupV02.id)
        #expect(trinity?.name == "Primordial Soup v0.2")
    }

    @Test("generates dense Primordial Soup v0.2 behavior spaces")
    func generatesDensePrimordialSoupV02BehaviorSpace() {
        var settings = PrimordialSoupLifecycleGenerationSettings.defaults
        settings.typeCount = 5
        settings.complexity = 1
        settings.forceComplexity = 1
        settings.seed = 42

        let behaviorSpace = PrimordialSoupLifecycleBehaviorSpaceGenerator.generate(settings: settings)

        #expect(behaviorSpace.typeProfiles.count == 5)
        #expect(behaviorSpace.relationships.count == 25)
        #expect(behaviorSpace.relationships.contains { $0.signedForce != 0 })
        #expect(behaviorSpace.relationships.contains { $0.energyCost != 0 })
    }

    @Test("derives Primordial Soup v0.2 render type count from behavior space")
    func derivesPrimordialSoupV02RenderTypeCountFromBehaviorSpace() throws {
        var generationSettings = PrimordialSoupLifecycleGenerationSettings.defaults
        generationSettings.typeCount = 9
        var settings = PrimordialSoupLifecycleSettings()
        settings.pendingGenerationSettings = generationSettings
        settings.activeBehaviorSpace = PrimordialSoupLifecycleBehaviorSpaceGenerator.generate(settings: generationSettings)

        let data = try JSONEncoder().encode(settings)
        let blob = String(data: data, encoding: .utf8)!
        let snapshot = MainWindowPhysicsModuleSettingsSnapshot(
            blobsByModuleName: [PrimordialSoupLifecycleSettings.moduleName: blob]
        )
        var editorState = SimulationEditorState()
        editorState.selectedTrinityID = TrinityCatalog.primordialSoupV02.id
        editorState.assignedModuleIDs = TrinityCatalog.primordialSoupV02.assignedModuleIDs

        let resolved = SimulationConfigurationDerivation.resolvedRuntimeConfiguration(
            editorState: editorState,
            transportState: .stopped,
            availableBundles: [
                moduleBundle(
                    id: "particularity.realtime.producer.fixed_grid",
                    kind: .optimization,
                    descriptor: ModuleCatalog.knownModulesByName[FixedGridOptimizationModuleRuntime.moduleName]!
                ),
                moduleBundle(
                    id: "particularity.realtime.processor.primordial_soup_lifecycle",
                    kind: .physics,
                    descriptor: ModuleCatalog.knownModulesByName[PrimordialSoupLifecycleSettings.moduleName]!
                ),
                moduleBundle(
                    id: ModuleCatalog.defaultVisual.moduleID,
                    kind: .visual,
                    descriptor: ModuleCatalog.defaultVisual
                ),
            ],
            physicsModuleSettingsSnapshot: snapshot
        )

        #expect(resolved.simulationState.particleTypes == 9)
    }

    @Test("matches toy playback trinity from its module trio")
    func matchesToyPlaybackTrinity() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.knownModulesByName["ToyPlaybackProcessor"]!,
            visual: ModuleCatalog.knownModulesByName["ToyPlaybackPresenter"]!,
            optimization: ModuleCatalog.knownModulesByName["ToyPlaybackReader"]!
        )

        #expect(TrinityCatalog.matching(modules)?.id == TrinityCatalog.toyPlayback.id)
    }

    @Test("accepts known ML playback trio")
    func acceptsKnownMLPlaybackTrio() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.knownModulesByName["MLTrainingPlaybackProcessor"]!,
            visual: ModuleCatalog.knownModulesByName["MLTrainingPlaybackPresenter"]!,
            optimization: ModuleCatalog.knownModulesByName["MLTrainingPlaybackReader"]!
        )

        #expect(ModuleCompatibility.incompatibilityReason(for: modules, state: viewportState()) == nil)
        #expect(TrinityCatalog.matching(modules)?.id == TrinityCatalog.mlTrainingPlayback.id)
    }

    @Test("persists selected trinity and local settings")
    func persistsSelectedTrinityAndLocalSettings() throws {
        var editorState = SimulationEditorState()
        editorState.selectedTrinityID = TrinityCatalog.primordialSoup.id
        editorState.trinitySettings[TrinityCatalog.primordialSoup.id] = TrinitySettingsSnapshot(
            physicsState: PhysicsModuleState(particleCount: 1234),
            playbackState: PlaybackModuleState(looping: false)
        )

        let data = try JSONEncoder().encode(MainWindowSimulationStateSnapshot.from(editorState: editorState))
        let decoded = try JSONDecoder().decode(MainWindowSimulationStateSnapshot.self, from: data)

        #expect(decoded.selectedTrinityID == TrinityCatalog.primordialSoup.id)
        #expect(decoded.trinitySettings[TrinityCatalog.primordialSoup.id]?.physicsState.particleCount == 1234)
        #expect(decoded.trinitySettings[TrinityCatalog.primordialSoup.id]?.playbackState.looping == false)
    }

    @Test("persists trinity local generic module settings")
    func persistsTrinityLocalGenericModuleSettings() throws {
        var editorState = SimulationEditorState()
        editorState.selectedTrinityID = TrinityCatalog.mlTrainingPlayback.id
        editorState.moduleSettings = [
            "particularity.playback.presenter.ml_training_presenter": [
                "surfaceMesh": .bool(true),
                "surfaceSmoothing": .number(0.35),
                "normalization": .text("perFrame"),
            ],
        ]
        editorState.trinitySettings[TrinityCatalog.mlTrainingPlayback.id] = TrinitySettingsSnapshot(
            moduleSettings: editorState.moduleSettings
        )

        let data = try JSONEncoder().encode(MainWindowSimulationStateSnapshot.from(editorState: editorState))
        let decoded = try JSONDecoder().decode(MainWindowSimulationStateSnapshot.self, from: data)
        let moduleSettings = decoded.trinitySettings[TrinityCatalog.mlTrainingPlayback.id]?.moduleSettings[
            "particularity.playback.presenter.ml_training_presenter"
        ]

        #expect(moduleSettings?["surfaceMesh"] == .bool(true))
        #expect(moduleSettings?["surfaceSmoothing"] == .number(0.35))
        #expect(moduleSettings?["normalization"] == .text("perFrame"))
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

    @Test("decodes module settings schema")
    func decodesModuleSettingsSchema() throws {
        let json = """
        {
          "id": "example.playback.presenter.demo",
          "name": "Demo Presenter",
          "kind": "visual",
          "version": 1,
          "executionModel": "playback",
          "pipelineStage": "presenter",
          "entryPoints": {},
          "settings": {
            "sections": [
              {
                "id": "surface",
                "title": "Surface",
                "controls": [
                  {
                    "id": "surfaceMesh",
                    "title": "Surface Mesh",
                    "type": "toggle",
                    "defaultValue": true
                  },
                  {
                    "id": "surfaceSmoothing",
                    "title": "Surface Smoothing",
                    "type": "slider",
                    "defaultValue": 0.35,
                    "minimum": 0,
                    "maximum": 1,
                    "step": 0.01
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: json)

        #expect(manifest.settings?.sections.count == 1)
        #expect(manifest.settings?.sections.first?.controls.count == 2)
        #expect(manifest.settings?.sections.first?.controls.first?.defaultValue == .bool(true))
        #expect(manifest.settings?.sections.first?.controls.last?.defaultValue == .number(0.35))
    }

    @Test("decodes module time scale profile")
    func decodesModuleTimeScaleProfile() throws {
        let json = """
        {
          "id": "example.playback.processor.demo",
          "name": "Demo Processor",
          "kind": "physics",
          "version": 1,
          "executionModel": "playback",
          "pipelineStage": "processor",
          "timeScale": {
            "minimum": 0.05,
            "maximum": 8.0,
            "defaultValue": 1.25,
            "step": 0.05
          },
          "entryPoints": {}
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: json)

        #expect(manifest.timeScale?.minimum == 0.05)
        #expect(manifest.timeScale?.maximum == 8.0)
        #expect(manifest.timeScale?.defaultValue == 1.25)
        #expect(manifest.timeScale?.step == 0.05)
    }

    @Test("decodes module simulation setup profile")
    func decodesModuleSimulationSetupProfile() throws {
        let json = """
        {
          "id": "example.realtime.processor.demo",
          "name": "Demo Processor",
          "kind": "physics",
          "version": 1,
          "executionModel": "realtime",
          "pipelineStage": "processor",
          "simulationSetup": {
            "particleCount": {
              "minimum": 1,
              "maximum": 50000,
              "defaultValue": 1000,
              "helpText": "Demo particle budget."
            },
            "randomDistribution": {
              "defaultValue": false
            },
            "interParticleCommunication": {
              "defaultValue": true
            },
            "particleTypes": {
              "minimum": 1,
              "maximum": 8,
              "defaultValue": 4
            }
          },
          "entryPoints": {}
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: json)

        #expect(manifest.simulationSetup?.particleCount?.maximum == 50_000)
        #expect(manifest.simulationSetup?.randomDistribution?.defaultValue == false)
        #expect(manifest.simulationSetup?.interParticleCommunication?.defaultValue == true)
        #expect(manifest.simulationSetup?.particleTypes?.maximum == 8)
    }

    @Test("playback processors do not expose simulation setup controls by default")
    func playbackProcessorsDoNotExposeSimulationSetupByDefault() {
        let modules = ActiveModuleSet(
            physics: ModuleCatalog.knownModulesByName["ToyPlaybackProcessor"]!,
            visual: ModuleCatalog.knownModulesByName["ToyPlaybackPresenter"]!,
            optimization: ModuleCatalog.knownModulesByName["ToyPlaybackReader"]!
        )

        #expect(modules.simulationSetupProfile.exposesAnyControl == false)
    }

    @Test("resolves simulation setup from processor module settings")
    func resolvesSimulationSetupFromProcessorModuleSettings() {
        var editorState = SimulationEditorState()
        editorState.physicsState.particleCount = 20_000
        editorState.physicsState.randomDistribution = true
        editorState.physicsState.particleTypes = 6
        editorState.physicsState.allParticlesIntercommunicate = true
        editorState.moduleSettings[ModuleCatalog.defaultPhysics.moduleID] = [
            ModuleSimulationSetupSettingID.particleCount: .number(1234),
            ModuleSimulationSetupSettingID.randomDistribution: .bool(false),
            ModuleSimulationSetupSettingID.particleTypes: .number(3),
            ModuleSimulationSetupSettingID.interParticleCommunication: .bool(false),
        ]

        let configuration = SimulationConfigurationDerivation.resolvedRuntimeConfiguration(
            editorState: editorState,
            transportState: .stopped,
            availableBundles: []
        )

        #expect(configuration.simulationState.particleCount == 1234)
        #expect(configuration.simulationState.randomDistribution == false)
        #expect(configuration.simulationState.particleTypes == 3)
        #expect(configuration.simulationState.allParticlesIntercommunicate == false)
    }

    @Test("derives Primordial Soup v0.1 render type count from processor setup")
    func derivesPrimordialSoupV01RenderTypeCountFromProcessorSetup() {
        var editorState = SimulationEditorState()
        editorState.assignedModuleIDs = TrinityCatalog.primordialSoup.assignedModuleIDs
        editorState.physicsState.particleTypes = 3
        editorState.moduleSettings["particularity.realtime.processor.type_matrix_local"] = [
            ModuleSimulationSetupSettingID.particleTypes: .number(11),
        ]

        let configuration = SimulationConfigurationDerivation.resolvedRuntimeConfiguration(
            editorState: editorState,
            transportState: .stopped,
            availableBundles: [
                moduleBundle(
                    id: "particularity.realtime.producer.fixed_grid",
                    kind: .optimization,
                    descriptor: ModuleCatalog.knownModulesByName[FixedGridOptimizationModuleRuntime.moduleName]!
                ),
                moduleBundle(
                    id: "particularity.realtime.processor.type_matrix_local",
                    kind: .physics,
                    descriptor: ModuleCatalog.knownModulesByName[TypeMatrixLocalPhysicsSettings.moduleName]!
                ),
                moduleBundle(
                    id: ModuleCatalog.defaultVisual.moduleID,
                    kind: .visual,
                    descriptor: ModuleCatalog.defaultVisual
                ),
            ]
        )

        #expect(configuration.simulationState.particleTypes == 11)
    }

    @Test("playback runtime setup does not inherit realtime particle setup")
    func playbackRuntimeSetupDoesNotInheritRealtimeParticleSetup() {
        var editorState = SimulationEditorState()
        editorState.assignedModuleIDs = TrinityCatalog.toyPlayback.assignedModuleIDs
        editorState.physicsState.particleCount = 50_000
        editorState.physicsState.particleTypes = 12
        editorState.physicsState.randomDistribution = true
        editorState.physicsState.allParticlesIntercommunicate = true

        let configuration = SimulationConfigurationDerivation.resolvedRuntimeConfiguration(
            editorState: editorState,
            transportState: .stopped,
            availableBundles: [
                moduleBundle(
                    id: "particularity.playback.producer.toy_reader",
                    kind: .optimization,
                    descriptor: ModuleCatalog.knownModulesByName["ToyPlaybackReader"]!
                ),
                moduleBundle(
                    id: "particularity.playback.processor.toy_processor",
                    kind: .physics,
                    descriptor: ModuleCatalog.knownModulesByName["ToyPlaybackProcessor"]!
                ),
                moduleBundle(
                    id: "particularity.playback.presenter.toy_presenter",
                    kind: .visual,
                    descriptor: ModuleCatalog.knownModulesByName["ToyPlaybackPresenter"]!
                ),
            ]
        )

        #expect(configuration.simulationState.particleCount == 1)
        #expect(configuration.simulationState.particleTypes == 1)
        #expect(configuration.simulationState.randomDistribution == false)
        #expect(configuration.simulationState.allParticlesIntercommunicate == false)
    }

    @Test("uses unified time scale for playback rate")
    func usesUnifiedTimeScaleForPlaybackRate() {
        var editorState = SimulationEditorState()
        editorState.assignedModuleIDs = TrinityCatalog.toyPlayback.assignedModuleIDs
        editorState.physicsState.timeScale = 2.5

        let configuration = SimulationConfigurationDerivation.resolvedRuntimeConfiguration(
            editorState: editorState,
            transportState: .running,
            availableBundles: [
                moduleBundle(
                    id: "particularity.playback.producer.toy_reader",
                    kind: .optimization,
                    descriptor: ModuleCatalog.knownModulesByName["ToyPlaybackReader"]!
                ),
                moduleBundle(
                    id: "particularity.playback.processor.toy_processor",
                    kind: .physics,
                    descriptor: ModuleCatalog.knownModulesByName["ToyPlaybackProcessor"]!
                ),
                moduleBundle(
                    id: "particularity.playback.presenter.toy_presenter",
                    kind: .visual,
                    descriptor: ModuleCatalog.knownModulesByName["ToyPlaybackPresenter"]!
                ),
            ]
        )

        #expect(configuration.simulationState.timeScale == 2.5)
        #expect(configuration.simulationState.playbackRate == 2.5)
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
            mlPlayback: MLPlaybackViewportSettings(),
            fixedGridSubdivisions: 1,
            fixedGridSubspaceCap: 1,
            fixedGridNeighborReadMode: .scratch
        )
    }
}
