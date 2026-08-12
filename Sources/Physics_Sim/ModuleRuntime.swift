import Foundation
import simd

enum BuildVisibility: String {
    case production
    case dev
}

enum SimulationTransportState: String {
    case stopped
    case running
    case paused

    var title: String {
        rawValue.capitalized
    }
}

enum SimulationParticleLimits {
    static let engineCap = 1_000_000
    static let settingsUICap = 250_000
}

struct PhysicsModuleState: Codable, Equatable, Sendable {
    var particleCount: Int = 20_000
    var randomDistribution = true
    var particleTypes: Int = 6
    var allParticlesIntercommunicate = true
    var movementDirection = SIMD3<Double>(0.82, 0.18, 0.12)
    var timeScale: Double = 1.0
}

struct ModuleTimeScaleProfile: Codable, Equatable, Sendable {
    var minimum: Double
    var maximum: Double
    var defaultValue: Double
    var step: Double

    static let realtimeDefault = ModuleTimeScaleProfile(
        minimum: 0.1,
        maximum: 4.0,
        defaultValue: 1.0,
        step: 0.01
    )

    static let playbackDefault = ModuleTimeScaleProfile(
        minimum: 0.05,
        maximum: 4.0,
        defaultValue: 1.0,
        step: 0.01
    )

    var range: ClosedRange<Double> {
        minimum...max(minimum, maximum)
    }

    func clamped(_ value: Double) -> Double {
        min(max(minimum, value), max(minimum, maximum))
    }
}

struct ModuleSimulationSetupProfile: Codable, Equatable, Sendable {
    var particleCount: ModuleParticleCountControl?
    var randomDistribution: ModuleBoolSetupControl?
    var interParticleCommunication: ModuleBoolSetupControl?
    var particleTypes: ModuleIntSetupControl?

    static let defaultRealtime = ModuleSimulationSetupProfile(
        particleCount: ModuleParticleCountControl(
            minimum: 1,
            maximum: SimulationParticleLimits.settingsUICap,
            defaultValue: 20_000,
            helpText: "UI cap: \(SimulationParticleLimits.settingsUICap.formatted()). Hard engine limit: \(SimulationParticleLimits.engineCap.formatted())."
        ),
        randomDistribution: ModuleBoolSetupControl(defaultValue: true),
        interParticleCommunication: ModuleBoolSetupControl(defaultValue: true),
        particleTypes: ModuleIntSetupControl(minimum: 1, maximum: 32, defaultValue: 6)
    )

    static let typeMatrixRealtime = ModuleSimulationSetupProfile(
        particleCount: ModuleParticleCountControl(
            minimum: 1,
            maximum: SimulationParticleLimits.settingsUICap,
            defaultValue: 20_000,
            helpText: "Uses the existing simulation particle count path."
        ),
        randomDistribution: ModuleBoolSetupControl(defaultValue: true),
        interParticleCommunication: ModuleBoolSetupControl(defaultValue: true),
        particleTypes: ModuleIntSetupControl(
            minimum: 1,
            maximum: TypeMatrixLocalPhysicsSettings.maxParticleTypes,
            defaultValue: 6
        )
    )

    var exposesAnyControl: Bool {
        particleCount != nil
            || randomDistribution != nil
            || interParticleCommunication != nil
            || particleTypes != nil
    }
}

enum ModuleSimulationSetupSettingID {
    static let particleCount = "particleCount"
    static let randomDistribution = "randomDistribution"
    static let interParticleCommunication = "interParticleCommunication"
    static let particleTypes = "particleTypes"
}

struct ResolvedSimulationSetup: Equatable, Sendable {
    var particleCount: Int
    var randomDistribution: Bool
    var particleTypes: Int
    var allParticlesIntercommunicate: Bool
}

enum ModuleSimulationSetupResolver {
    static func resolve(
        editorState: SimulationEditorState,
        activeModules: ActiveModuleSet
    ) -> ResolvedSimulationSetup {
        let profile = activeModules.simulationSetupProfile
        let moduleID = activeModules.physics.moduleID
        let moduleSettings = editorState.moduleSettings[moduleID] ?? [:]

        let particleCount = profile.particleCount.map { control in
            let fallback = min(max(control.range.lowerBound, editorState.physicsState.particleCount), control.range.upperBound)
            return min(
                max(
                    control.range.lowerBound,
                    Int(moduleSettings[ModuleSimulationSetupSettingID.particleCount]?.numberValue?.rounded() ?? Double(fallback))
                ),
                control.range.upperBound
            )
        } ?? 1

        let randomDistribution = profile.randomDistribution.map { control in
            moduleSettings[ModuleSimulationSetupSettingID.randomDistribution]?.boolValue
                ?? editorState.physicsState.randomDistribution
        } ?? false

        let particleTypes = profile.particleTypes.map { control in
            let fallback = min(max(control.range.lowerBound, editorState.physicsState.particleTypes), control.range.upperBound)
            return min(
                max(
                    control.range.lowerBound,
                    Int(moduleSettings[ModuleSimulationSetupSettingID.particleTypes]?.numberValue?.rounded() ?? Double(fallback))
                ),
                control.range.upperBound
            )
        } ?? 1

        let allParticlesIntercommunicate = profile.interParticleCommunication.map { control in
            moduleSettings[ModuleSimulationSetupSettingID.interParticleCommunication]?.boolValue
                ?? editorState.physicsState.allParticlesIntercommunicate
        } ?? false

        return ResolvedSimulationSetup(
            particleCount: particleCount,
            randomDistribution: randomDistribution,
            particleTypes: particleTypes,
            allParticlesIntercommunicate: allParticlesIntercommunicate
        )
    }
}

struct ModuleParticleCountControl: Codable, Equatable, Sendable {
    var minimum: Int
    var maximum: Int
    var defaultValue: Int
    var helpText: String?

    var range: ClosedRange<Int> {
        max(1, minimum)...max(max(1, minimum), maximum)
    }
}

struct ModuleIntSetupControl: Codable, Equatable, Sendable {
    var minimum: Int
    var maximum: Int
    var defaultValue: Int

    var range: ClosedRange<Int> {
        max(1, minimum)...max(max(1, minimum), maximum)
    }
}

struct ModuleBoolSetupControl: Codable, Equatable, Sendable {
    var defaultValue: Bool
}

struct VisualModuleState: Codable, Equatable, Sendable {
    var sphereSize: Double = 0.008
    var spectrumOffset: Double = 0.0
    var showOptimizationInfo = false
}

struct OptimizationModuleState: Codable, Equatable, Sendable {
    var showLeaderCommunicationLog = false
    var fixedGridSubdivisions: Int = FixedGridOptimizationModuleRuntime.defaultSubdivisions
    var fixedGridSubspaceCap: Int = 2
    var fixedGridNeighborReadMode: FixedGridNeighborReadMode = .scratch
}

enum FixedGridNeighborReadMode: String, Codable, CaseIterable, Equatable, Sendable {
    case raw
    case scratch

    var title: String {
        switch self {
        case .raw:
            return "Raw"
        case .scratch:
            return "Scratch"
        }
    }
}

struct DebugSettingsState: Codable, Equatable, Sendable {
    var protectLeaderFromUnload = true
}

enum ModuleSettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var textValue: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .text(let value):
            try container.encode(value)
        }
    }
}

struct ModuleSettingsSchema: Decodable, Equatable, Sendable {
    var sections: [ModuleSettingsSection]

    static let empty = ModuleSettingsSchema(sections: [])
}

struct ModuleSettingsSection: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String?
    var controls: [ModuleSettingControl]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case controls
    }
}

struct ModuleSettingOption: Decodable, Equatable, Sendable, Identifiable {
    var id: String { value }
    var value: String
    var title: String
}

enum ModuleSettingControlType: String, Decodable, Equatable, Sendable {
    case toggle
    case slider
    case intSlider
    case segmented
    case text
}

struct ModuleSettingControl: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var type: ModuleSettingControlType
    var defaultValue: ModuleSettingValue
    var minimum: Double?
    var maximum: Double?
    var step: Double?
    var helpText: String?
    var options: [ModuleSettingOption]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case defaultValue
        case minimum
        case maximum
        case step
        case helpText
        case options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        type = try container.decode(ModuleSettingControlType.self, forKey: .type)
        defaultValue = try container.decode(ModuleSettingValue.self, forKey: .defaultValue)
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
        step = try container.decodeIfPresent(Double.self, forKey: .step)
        helpText = try container.decodeIfPresent(String.self, forKey: .helpText)
        options = try container.decodeIfPresent([ModuleSettingOption].self, forKey: .options) ?? []
    }
}

struct PlaybackModuleState: Codable, Equatable, Sendable {
    var looping = true
}

enum ModuleKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case physics
    case visual
    case optimization

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .physics: return "Processor Module"
        case .visual: return "Presenter Module"
        case .optimization: return "Producer Module"
        }
    }

    var folderName: String {
        switch self {
        case .physics: return "Physics"
        case .visual: return "Visual"
        case .optimization: return "Optimization"
        }
    }

    var shortTitle: String {
        switch self {
        case .physics: return "Physics"
        case .visual: return "Visual"
        case .optimization: return "Optimization"
        }
    }
}

enum ModuleExecutionModel: String, Codable, CaseIterable, Equatable, Sendable {
    case realtime
    case playback

    var title: String {
        switch self {
        case .realtime: return "Realtime"
        case .playback: return "Playback"
        }
    }
}

enum ModulePipelineStage: String, Codable, CaseIterable, Equatable, Sendable {
    case producer
    case processor
    case presenter

    var title: String {
        switch self {
        case .producer: return "Producer"
        case .processor: return "Processor"
        case .presenter: return "Presenter"
        }
    }
}

enum ModuleRoleMapping {
    static func defaultExecutionModel(for kind: String) -> ModuleExecutionModel {
        .realtime
    }

    static func defaultPipelineStage(for kind: String) -> ModulePipelineStage {
        switch kind {
        case ModuleKind.optimization.rawValue:
            return .producer
        case ModuleKind.physics.rawValue:
            return .processor
        case ModuleKind.visual.rawValue:
            return .presenter
        default:
            return .processor
        }
    }

    static func expectedPipelineStage(for kind: ModuleKind) -> ModulePipelineStage {
        defaultPipelineStage(for: kind.rawValue)
    }

    static func stageName(
        executionModel: ModuleExecutionModel,
        pipelineStage: ModulePipelineStage
    ) -> String {
        switch executionModel {
        case .realtime:
            switch pipelineStage {
            case .producer: return "Optimization"
            case .processor: return "Physics"
            case .presenter: return "Visual"
            }
        case .playback:
            switch pipelineStage {
            case .producer: return "Reader"
            case .processor: return "Processor"
            case .presenter: return "Visual"
            }
        }
    }
}

struct SimulationEditorState: Equatable {
    var physicsState = PhysicsModuleState()
    var visualState = VisualModuleState()
    var optimizationState = OptimizationModuleState()
    var playbackState = PlaybackModuleState()
    var debugSettings = DebugSettingsState()
    var moduleSettings: [String: [String: ModuleSettingValue]] = [:]
    var assignedModuleIDs: [String: String] = [:]
    var selectedTrinityID: String? = TrinityCatalog.defaultRealtime.id
    var trinitySettings: [String: TrinitySettingsSnapshot] = [:]
}

struct TrinitySettingsSnapshot: Codable, Equatable, Sendable {
    var physicsState = PhysicsModuleState()
    var visualState = VisualModuleState()
    var optimizationState = OptimizationModuleState()
    var playbackState = PlaybackModuleState()
    var debugSettings = DebugSettingsState()
    var moduleSettings: [String: [String: ModuleSettingValue]] = [:]

    static let `default` = TrinitySettingsSnapshot()

    init(
        physicsState: PhysicsModuleState = PhysicsModuleState(),
        visualState: VisualModuleState = VisualModuleState(),
        optimizationState: OptimizationModuleState = OptimizationModuleState(),
        playbackState: PlaybackModuleState = PlaybackModuleState(),
        debugSettings: DebugSettingsState = DebugSettingsState(),
        moduleSettings: [String: [String: ModuleSettingValue]] = [:]
    ) {
        self.physicsState = physicsState
        self.visualState = visualState
        self.optimizationState = optimizationState
        self.playbackState = playbackState
        self.debugSettings = debugSettings
        self.moduleSettings = moduleSettings
    }
}

struct TrinityDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let executionModel: ModuleExecutionModel
    let moduleIDs: [ModuleKind: String]
    let assignedModuleIDs: [String: String]
    let defaultSettings: TrinitySettingsSnapshot

    func matches(_ modules: ActiveModuleSet) -> Bool {
        moduleIDs[.optimization] == modules.optimization.moduleID
            && moduleIDs[.physics] == modules.physics.moduleID
            && moduleIDs[.visual] == modules.visual.moduleID
    }
}

enum TrinityCatalog {
    static let defaultRealtime = TrinityDefinition(
        id: "particularity.trinity.default_realtime",
        name: "Default",
        executionModel: .realtime,
        moduleIDs: [
            .optimization: ModuleCatalog.defaultOptimization.moduleID,
            .physics: ModuleCatalog.defaultPhysics.moduleID,
            .visual: ModuleCatalog.defaultVisual.moduleID,
        ],
        assignedModuleIDs: [:],
        defaultSettings: .default
    )

    static let primordialSoup = TrinityDefinition(
        id: "particularity.trinity.primordial_soup_v0_1",
        name: "Primordial Soup v0.1",
        executionModel: .realtime,
        moduleIDs: [
            .optimization: "particularity.realtime.producer.fixed_grid",
            .physics: "particularity.realtime.processor.type_matrix_local",
            .visual: ModuleCatalog.defaultVisual.moduleID,
        ],
        assignedModuleIDs: [
            ModuleKind.optimization.rawValue: "particularity.realtime.producer.fixed_grid",
            ModuleKind.physics.rawValue: "particularity.realtime.processor.type_matrix_local",
        ],
        defaultSettings: .default
    )

    static let primordialSoupV02 = TrinityDefinition(
        id: "particularity.trinity.primordial_soup_v0_2",
        name: "Primordial Soup v0.2",
        executionModel: .realtime,
        moduleIDs: [
            .optimization: "particularity.realtime.producer.fixed_grid",
            .physics: "particularity.realtime.processor.primordial_soup_lifecycle",
            .visual: ModuleCatalog.defaultVisual.moduleID,
        ],
        assignedModuleIDs: [
            ModuleKind.optimization.rawValue: "particularity.realtime.producer.fixed_grid",
            ModuleKind.physics.rawValue: "particularity.realtime.processor.primordial_soup_lifecycle",
        ],
        defaultSettings: .default
    )

    static let toyPlayback = TrinityDefinition(
        id: "particularity.trinity.toy_playback",
        name: "Toy Playback",
        executionModel: .playback,
        moduleIDs: [
            .optimization: "particularity.playback.producer.toy_reader",
            .physics: "particularity.playback.processor.toy_processor",
            .visual: "particularity.playback.presenter.toy_presenter",
        ],
        assignedModuleIDs: [
            ModuleKind.optimization.rawValue: "particularity.playback.producer.toy_reader",
            ModuleKind.physics.rawValue: "particularity.playback.processor.toy_processor",
            ModuleKind.visual.rawValue: "particularity.playback.presenter.toy_presenter",
        ],
        defaultSettings: .default
    )

    static let mlTrainingPlayback = TrinityDefinition(
        id: "particularity.trinity.ml_training_playback",
        name: "ML Training Playback",
        executionModel: .playback,
        moduleIDs: [
            .optimization: "particularity.playback.producer.ml_training_reader",
            .physics: "particularity.playback.processor.ml_training_processor",
            .visual: "particularity.playback.presenter.ml_training_presenter",
        ],
        assignedModuleIDs: [
            ModuleKind.optimization.rawValue: "particularity.playback.producer.ml_training_reader",
            ModuleKind.physics.rawValue: "particularity.playback.processor.ml_training_processor",
            ModuleKind.visual.rawValue: "particularity.playback.presenter.ml_training_presenter",
        ],
        defaultSettings: .default
    )

    static let all: [TrinityDefinition] = [
        defaultRealtime,
        primordialSoup,
        primordialSoupV02,
        toyPlayback,
        mlTrainingPlayback,
    ]

    static func definition(id: String?) -> TrinityDefinition? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func matching(_ modules: ActiveModuleSet) -> TrinityDefinition? {
        all.first { $0.matches(modules) }
    }
}

struct ModuleDescriptor: Identifiable, Equatable {
    let moduleID: String
    let kind: String
    let name: String
    let version: Int
    let visibility: BuildVisibility
    let isDefaultFallback: Bool
    let acceptsOptimizationDebugInfo: Bool
    let providesOptimizationDebugInfo: Bool
    let supportsLeaderCommunicationLog: Bool
    let moduleFamilyID: String?
    let consumesContracts: [String]
    let producesContracts: [String]
    let executionModel: ModuleExecutionModel
    let pipelineStage: ModulePipelineStage
    let entryPoints: ModuleEntryPoints
    let timeScale: ModuleTimeScaleProfile?
    let simulationSetup: ModuleSimulationSetupProfile?

    init(
        moduleID: String? = nil,
        kind: String,
        name: String,
        version: Int = 1,
        visibility: BuildVisibility,
        isDefaultFallback: Bool,
        acceptsOptimizationDebugInfo: Bool,
        providesOptimizationDebugInfo: Bool,
        supportsLeaderCommunicationLog: Bool,
        moduleFamilyID: String? = nil,
        consumesContracts: [String] = [],
        producesContracts: [String] = [],
        executionModel: ModuleExecutionModel? = nil,
        pipelineStage: ModulePipelineStage? = nil,
        entryPoints: ModuleEntryPoints = ModuleEntryPoints(),
        timeScale: ModuleTimeScaleProfile? = nil,
        simulationSetup: ModuleSimulationSetupProfile? = nil
    ) {
        self.moduleID = moduleID ?? "internal.\(kind).\(name)"
        self.kind = kind
        self.name = name
        self.version = version
        self.visibility = visibility
        self.isDefaultFallback = isDefaultFallback
        self.acceptsOptimizationDebugInfo = acceptsOptimizationDebugInfo
        self.providesOptimizationDebugInfo = providesOptimizationDebugInfo
        self.supportsLeaderCommunicationLog = supportsLeaderCommunicationLog
        self.moduleFamilyID = moduleFamilyID
        self.consumesContracts = consumesContracts
        self.producesContracts = producesContracts
        self.executionModel = executionModel ?? ModuleRoleMapping.defaultExecutionModel(for: kind)
        self.pipelineStage = pipelineStage ?? ModuleRoleMapping.defaultPipelineStage(for: kind)
        self.entryPoints = entryPoints
        self.timeScale = timeScale
        self.simulationSetup = simulationSetup
    }

    var id: String {
        moduleID
    }

    var roleDisplayName: String {
        ModuleRoleMapping.stageName(executionModel: executionModel, pipelineStage: pipelineStage)
    }

    func withPipelineMetadata(
        moduleID: String? = nil,
        version: Int? = nil,
        moduleFamilyID: String? = nil,
        consumesContracts: [String]? = nil,
        producesContracts: [String]? = nil,
        executionModel: ModuleExecutionModel?,
        pipelineStage: ModulePipelineStage?,
        entryPoints: ModuleEntryPoints? = nil,
        timeScale: ModuleTimeScaleProfile? = nil,
        simulationSetup: ModuleSimulationSetupProfile? = nil
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: moduleID ?? self.moduleID,
            kind: kind,
            name: name,
            version: version ?? self.version,
            visibility: visibility,
            isDefaultFallback: isDefaultFallback,
            acceptsOptimizationDebugInfo: acceptsOptimizationDebugInfo,
            providesOptimizationDebugInfo: providesOptimizationDebugInfo,
            supportsLeaderCommunicationLog: supportsLeaderCommunicationLog,
            moduleFamilyID: moduleFamilyID ?? self.moduleFamilyID,
            consumesContracts: consumesContracts ?? self.consumesContracts,
            producesContracts: producesContracts ?? self.producesContracts,
            executionModel: executionModel ?? self.executionModel,
            pipelineStage: pipelineStage ?? self.pipelineStage,
            entryPoints: entryPoints ?? self.entryPoints,
            timeScale: timeScale ?? self.timeScale,
            simulationSetup: simulationSetup ?? self.simulationSetup
        )
    }
}

struct ModuleEntryPoints: Decodable, Equatable {
    var initialize: [String]
    var preUpdate: [String]
    var update: [String]
    var postUpdate: [String]
    var teardown: [String]
    var vertex: [String]
    var fragment: [String]

    init(
        initialize: [String] = [],
        preUpdate: [String] = [],
        update: [String] = [],
        postUpdate: [String] = [],
        teardown: [String] = [],
        vertex: [String] = [],
        fragment: [String] = []
    ) {
        self.initialize = initialize
        self.preUpdate = preUpdate
        self.update = update
        self.postUpdate = postUpdate
        self.teardown = teardown
        self.vertex = vertex
        self.fragment = fragment
    }

    private enum CodingKeys: String, CodingKey {
        case initialize
        case preUpdate
        case update
        case postUpdate
        case teardown
        case vertex
        case fragment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        initialize = try container.decodeEntryPointListIfPresent(forKey: .initialize)
        preUpdate = try container.decodeEntryPointListIfPresent(forKey: .preUpdate)
        update = try container.decodeEntryPointListIfPresent(forKey: .update)
        postUpdate = try container.decodeEntryPointListIfPresent(forKey: .postUpdate)
        teardown = try container.decodeEntryPointListIfPresent(forKey: .teardown)
        vertex = try container.decodeEntryPointListIfPresent(forKey: .vertex)
        fragment = try container.decodeEntryPointListIfPresent(forKey: .fragment)
    }
}

private extension KeyedDecodingContainer {
    func decodeEntryPointListIfPresent(forKey key: Key) throws -> [String] {
        if let list = try? decodeIfPresent([String].self, forKey: key) {
            return list
        }
        if let single = try decodeIfPresent(String.self, forKey: key) {
            return [single]
        }
        return []
    }
}

struct ModuleManifest: Decodable, Equatable {
    let id: String
    let name: String
    let kind: String
    let version: Int
    let moduleFamilyID: String?
    let consumesContracts: [String]
    let producesContracts: [String]
    let executionModel: ModuleExecutionModel
    let pipelineStage: ModulePipelineStage
    let shaderSource: String?
    let entryPoints: ModuleEntryPoints
    let settings: ModuleSettingsSchema?
    let timeScale: ModuleTimeScaleProfile?
    let simulationSetup: ModuleSimulationSetupProfile?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case version
        case moduleFamilyID
        case consumesContracts
        case producesContracts
        case executionModel
        case pipelineStage
        case shaderSource
        case entryPoints
        case settings
        case timeScale
        case simulationSetup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(String.self, forKey: .kind)
        version = try container.decode(Int.self, forKey: .version)
        moduleFamilyID = try container.decodeIfPresent(String.self, forKey: .moduleFamilyID)
        consumesContracts = try container.decodeIfPresent([String].self, forKey: .consumesContracts) ?? []
        producesContracts = try container.decodeIfPresent([String].self, forKey: .producesContracts) ?? []
        executionModel = try container.decode(ModuleExecutionModel.self, forKey: .executionModel)
        pipelineStage = try container.decode(ModulePipelineStage.self, forKey: .pipelineStage)
        shaderSource = try container.decodeIfPresent(String.self, forKey: .shaderSource)
        entryPoints = try container.decodeIfPresent(ModuleEntryPoints.self, forKey: .entryPoints) ?? ModuleEntryPoints()
        settings = try container.decodeIfPresent(ModuleSettingsSchema.self, forKey: .settings)
        timeScale = try container.decodeIfPresent(ModuleTimeScaleProfile.self, forKey: .timeScale)
        simulationSetup = try container.decodeIfPresent(ModuleSimulationSetupProfile.self, forKey: .simulationSetup)
    }
}

enum ModuleCatalog {
    static let toyPlaybackFamilyID = "particularity.playback.family.toy_v1"
    static let toyPlaybackSourceContract = "particularity.playback.toy_source.v1"
    static let toyPlaybackParticleSurfaceContract = "particularity.presentation.toy_particle_surface.v1"
    static let mlPlaybackFamilyID = "particularity.playback.family.ml_training_v1"
    static let mlPlaybackSourceContract = "particularity.playback.ml_training_source.v1"
    static let mlPlaybackParticleSurfaceContract = "particularity.presentation.ml_training_particle_surface.v1"

    static let defaultPhysics = ModuleDescriptor(
        moduleID: "internal.realtime.processor.default_physics_slide_loop",
        kind: "physics",
        name: "DefaultPhysicsSlideLoop",
        visibility: .production,
        isDefaultFallback: true,
        acceptsOptimizationDebugInfo: false,
        providesOptimizationDebugInfo: false,
        supportsLeaderCommunicationLog: false,
        timeScale: .realtimeDefault,
        simulationSetup: .defaultRealtime
    )

    static let defaultVisual = ModuleDescriptor(
        moduleID: "internal.realtime.presenter.default_rainbow_unlit_spheres",
        kind: "visual",
        name: "DefaultRainbowUnlitSpheres",
        visibility: .production,
        isDefaultFallback: true,
        acceptsOptimizationDebugInfo: true,
        providesOptimizationDebugInfo: false,
        supportsLeaderCommunicationLog: false
    )

    static let defaultOptimization = ModuleDescriptor(
        moduleID: "internal.realtime.producer.default_optimization_all_pairs",
        kind: "optimization",
        name: "DefaultOptimizationAllPairs",
        visibility: .production,
        isDefaultFallback: true,
        acceptsOptimizationDebugInfo: false,
        providesOptimizationDebugInfo: true,
        supportsLeaderCommunicationLog: true
    )

    static let knownModulesByName: [String: ModuleDescriptor] = [
        PhysicsModuleTemplateRuntime.moduleName: ModuleDescriptor(
            moduleID: "particularity.realtime.processor.physics_module_template",
            kind: "physics",
            name: PhysicsModuleTemplateRuntime.moduleName,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            timeScale: .realtimeDefault,
            simulationSetup: .defaultRealtime
        ),
        "TypeMatrixLocalAttractionRepulsion": ModuleDescriptor(
            moduleID: "particularity.realtime.processor.type_matrix_local",
            kind: "physics",
            name: "TypeMatrixLocalAttractionRepulsion",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            timeScale: .realtimeDefault,
            simulationSetup: .typeMatrixRealtime
        ),
        PrimordialSoupLifecycleSettings.moduleName: ModuleDescriptor(
            moduleID: "particularity.realtime.processor.primordial_soup_lifecycle",
            kind: "physics",
            name: PrimordialSoupLifecycleSettings.moduleName,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            timeScale: .realtimeDefault,
            simulationSetup: ModuleSimulationSetupProfile(
                particleCount: ModuleParticleCountControl(
                    minimum: 1,
                    maximum: SimulationParticleLimits.settingsUICap,
                    defaultValue: PrimordialSoupLifecycleSettings.particleCapacityDefault,
                    helpText: "Maximum particle capacity for Primordial Soup v0.2."
                ),
                randomDistribution: nil,
                interParticleCommunication: nil,
                particleTypes: nil
            )
        ),
        "DefaultGreySpheres": ModuleDescriptor(
            moduleID: "particularity.realtime.presenter.default_grey_spheres",
            kind: "visual",
            name: "DefaultGreySpheres",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false
        ),
        FixedGridOptimizationModuleRuntime.moduleName: ModuleDescriptor(
            moduleID: "particularity.realtime.producer.fixed_grid",
            kind: "optimization",
            name: FixedGridOptimizationModuleRuntime.moduleName,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: true,
            supportsLeaderCommunicationLog: true
        ),
        "ToyPlaybackReader": ModuleDescriptor(
            moduleID: "particularity.playback.producer.toy_reader",
            kind: "optimization",
            name: "ToyPlaybackReader",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: toyPlaybackFamilyID,
            producesContracts: [toyPlaybackSourceContract],
            executionModel: .playback,
            pipelineStage: .producer
        ),
        "ToyPlaybackProcessor": ModuleDescriptor(
            moduleID: "particularity.playback.processor.toy_processor",
            kind: "physics",
            name: "ToyPlaybackProcessor",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: toyPlaybackFamilyID,
            consumesContracts: [toyPlaybackSourceContract],
            producesContracts: [toyPlaybackParticleSurfaceContract],
            executionModel: .playback,
            pipelineStage: .processor,
            timeScale: .playbackDefault
        ),
        "ToyPlaybackPresenter": ModuleDescriptor(
            moduleID: "particularity.playback.presenter.toy_presenter",
            kind: "visual",
            name: "ToyPlaybackPresenter",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: toyPlaybackFamilyID,
            consumesContracts: [toyPlaybackParticleSurfaceContract],
            executionModel: .playback,
            pipelineStage: .presenter
        ),
        "MLTrainingPlaybackReader": ModuleDescriptor(
            moduleID: "particularity.playback.producer.ml_training_reader",
            kind: "optimization",
            name: "MLTrainingPlaybackReader",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: mlPlaybackFamilyID,
            producesContracts: [mlPlaybackSourceContract],
            executionModel: .playback,
            pipelineStage: .producer
        ),
        "MLTrainingPlaybackProcessor": ModuleDescriptor(
            moduleID: "particularity.playback.processor.ml_training_processor",
            kind: "physics",
            name: "MLTrainingPlaybackProcessor",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: mlPlaybackFamilyID,
            consumesContracts: [mlPlaybackSourceContract],
            producesContracts: [mlPlaybackParticleSurfaceContract],
            executionModel: .playback,
            pipelineStage: .processor,
            timeScale: .playbackDefault
        ),
        "MLTrainingPlaybackPresenter": ModuleDescriptor(
            moduleID: "particularity.playback.presenter.ml_training_presenter",
            kind: "visual",
            name: "MLTrainingPlaybackPresenter",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: mlPlaybackFamilyID,
            consumesContracts: [mlPlaybackParticleSurfaceContract],
            executionModel: .playback,
            pipelineStage: .presenter
        ),
    ]

    static func fallback(for kind: String) -> ModuleDescriptor {
        switch kind {
        case "physics":
            return defaultPhysics
        case "visual":
            return defaultVisual
        case "optimization":
            return defaultOptimization
        default:
            return defaultPhysics
        }
    }
}

enum RuntimeValidationField: Hashable {
    case assignedModule(ModuleKind)
    case particleCount
    case randomDistribution
    case allParticlesIntercommunicate
    case particleTypes
    case timeScale
    case sphereSize
    case spectrumOffset
    case showOptimizationInfo
    case showLeaderCommunicationLog
    case moduleSetting(moduleName: String, key: String)
}

struct RuntimeValidationIssue: Identifiable, Equatable {
    let field: RuntimeValidationField?
    let message: String

    var id: String {
        "\(String(describing: field))|\(message)"
    }
}

struct RuntimeValidationReport {
    let issues: [RuntimeValidationIssue]
    let projectedBytes: UInt64

    var canStart: Bool {
        issues.isEmpty
    }

    var issue: String? {
        issues.first?.message
    }

    func issue(for field: RuntimeValidationField) -> RuntimeValidationIssue? {
        issues.first { $0.field == field }
    }
}

struct ActiveModuleSet: Equatable {
    var physics: ModuleDescriptor
    var visual: ModuleDescriptor
    var optimization: ModuleDescriptor

    var completeModuleFamilyID: String? {
        guard let physicsFamilyID = physics.moduleFamilyID,
              physicsFamilyID == visual.moduleFamilyID,
              physicsFamilyID == optimization.moduleFamilyID else {
            return nil
        }
        return physicsFamilyID
    }

    var hasPartialModuleFamilySelection: Bool {
        let familyIDs = [physics.moduleFamilyID, visual.moduleFamilyID, optimization.moduleFamilyID]
            .compactMap { $0 }
        return !familyIDs.isEmpty && completeModuleFamilyID == nil
    }

    var descriptors: [ModuleDescriptor] {
        [optimization, physics, visual]
    }

    var executionModel: ModuleExecutionModel? {
        let models = Set(descriptors.map(\.executionModel))
        return models.count == 1 ? models.first : nil
    }

    var isPlayback: Bool {
        descriptors.allSatisfy { $0.executionModel == .playback }
    }

    var timeScaleProfile: ModuleTimeScaleProfile {
        physics.timeScale
            ?? optimization.timeScale
            ?? visual.timeScale
            ?? (isPlayback ? .playbackDefault : .realtimeDefault)
    }

    var simulationSetupProfile: ModuleSimulationSetupProfile {
        physics.simulationSetup ?? ModuleSimulationSetupProfile()
    }
}

struct ResolvedRuntimeConfiguration {
    let simulationState: SimulationViewportState
    let activeModules: ActiveModuleSet
    let validationReport: RuntimeValidationReport
}

enum ModuleCompatibility {
    static func incompatibilityReason(for modules: ActiveModuleSet, state: SimulationViewportState) -> String? {
        if let issue = pipelineRoleIncompatibilityReason(for: modules) {
            return issue
        }

        if let issue = runtimeSupportIncompatibilityReason(for: modules) {
            return issue
        }

        if modules.hasPartialModuleFamilySelection {
            return "Playback module families must be selected as a compatible physics, visual, and optimization trio."
        }

        if let issue = contractIncompatibilityReason(for: modules) {
            return issue
        }

        if state.showOptimizationInfo && !modules.visual.acceptsOptimizationDebugInfo {
            return "Visual module \(modules.visual.name) does not accept optimization debug data."
        }

        if state.showOptimizationInfo && !modules.optimization.providesOptimizationDebugInfo {
            return "Optimization module \(modules.optimization.name) does not provide optimization debug data."
        }

        return nil
    }

    static func runtimeSupportIncompatibilityReason(for descriptor: ModuleDescriptor) -> String? {
        if descriptor.isDefaultFallback || ModuleCatalog.knownModulesByName[descriptor.name] != nil {
            return nil
        }

        if descriptor.executionModel == .realtime,
           descriptor.pipelineStage == .processor,
           descriptor.kind == ModuleKind.physics.rawValue {
            if descriptor.entryPoints.update.isEmpty || descriptor.entryPoints.postUpdate.isEmpty {
                return "Physics module \(descriptor.name) uses the standard realtime processor runtime, but it must declare update and postUpdate entry points."
            }
            return nil
        }

        return "\(descriptor.roleDisplayName) module \(descriptor.name) is discoverable, but this build does not yet support manifest-driven \(descriptor.roleDisplayName.lowercased()) execution."
    }

    private static func contractIncompatibilityReason(for modules: ActiveModuleSet) -> String? {
        guard modules.isPlayback else { return nil }

        let producerContracts = Set(modules.optimization.producesContracts)
        let processorInputContracts = Set(modules.physics.consumesContracts)
        guard !producerContracts.isDisjoint(with: processorInputContracts) else {
            return "Playback processor \(modules.physics.name) does not consume any contract produced by reader \(modules.optimization.name)."
        }

        let processorOutputContracts = Set(modules.physics.producesContracts)
        let presenterInputContracts = Set(modules.visual.consumesContracts)
        guard !processorOutputContracts.isDisjoint(with: presenterInputContracts) else {
            return "Playback visual \(modules.visual.name) does not consume any contract produced by processor \(modules.physics.name)."
        }

        return nil
    }

    private static func pipelineRoleIncompatibilityReason(for modules: ActiveModuleSet) -> String? {
        let descriptorsByKind: [(ModuleKind, ModuleDescriptor)] = [
            (.optimization, modules.optimization),
            (.physics, modules.physics),
            (.visual, modules.visual),
        ]

        for (kind, descriptor) in descriptorsByKind {
            let expectedStage = ModuleRoleMapping.expectedPipelineStage(for: kind)
            guard descriptor.pipelineStage == expectedStage else {
                return "\(kind.displayName) \(descriptor.name) declares pipeline stage \(descriptor.pipelineStage.title), but this slot requires \(expectedStage.title)."
            }
        }

        let executionModels = Set(modules.descriptors.map(\.executionModel))
        guard executionModels.count == 1 else {
            let modelList = modules.descriptors
                .map { "\($0.name): \($0.executionModel.title)" }
                .joined(separator: ", ")
            return "Active modules must share one execution model. Current selection: \(modelList)."
        }

        let stages = modules.descriptors.map(\.pipelineStage)
        for requiredStage in ModulePipelineStage.allCases {
            let count = stages.filter { $0 == requiredStage }.count
            guard count == 1 else {
                return "Active modules must include exactly one \(requiredStage.title.lowercased()) stage."
            }
        }

        return nil
    }

    private static func runtimeSupportIncompatibilityReason(for modules: ActiveModuleSet) -> String? {
        for descriptor in modules.descriptors {
            if let issue = runtimeSupportIncompatibilityReason(for: descriptor) {
                return issue
            }
        }
        return nil
    }
}

struct SimulationViewportState: Equatable {
    var transportState: SimulationTransportState
    var particleCount: Int
    var randomDistribution: Bool
    var particleTypes: Int
    var allParticlesIntercommunicate: Bool
    var movementDirection: SIMD3<Float>
    var timeScale: Float
    var sphereSize: Float
    var spectrumOffset: Float
    var showOptimizationInfo: Bool
    var showLeaderCommunicationLog: Bool
    var playbackRate: Float
    var playbackLooping: Bool
    var mlPlayback: MLPlaybackViewportSettings
    var fixedGridSubdivisions: Int
    var fixedGridSubspaceCap: Int
    var fixedGridNeighborReadMode: FixedGridNeighborReadMode
}

enum MLPlaybackSurfaceSelectionMode: String, Equatable, Hashable {
    case frontMiddleFinal
    case all
}

enum MLPlaybackNormalizationMode: String, Equatable, Hashable {
    case perFrame
    case global
}

enum MLPlaybackVisualRecipe: String, Equatable {
    case typeSpectrum
    case confidenceMargin
    case predictionDelta

    var rawValueForShader: Int {
        switch self {
        case .typeSpectrum:
            return 0
        case .confidenceMargin:
            return 1
        case .predictionDelta:
            return 2
        }
    }
}

struct MLPlaybackLayerSettings: Equatable, Hashable {
    var visible: Bool = true
    var slot: Int = 0
    var horizontalOffset: Float = 0
    var heightOffset: Float = 0
}

struct MLPlaybackViewportSettings: Equatable {
    var isActive: Bool = false
    var interpolationEnabled: Bool = true
    var surfaceSelectionMode: MLPlaybackSurfaceSelectionMode = .frontMiddleFinal
    var surfaceMeshEnabled: Bool = true
    var surfaceSmoothing: Float = 0.35
    var normalizationMode: MLPlaybackNormalizationMode = .perFrame
    var amplitudeScale: Float = 0.72
    var visualRecipe: MLPlaybackVisualRecipe = .typeSpectrum
    var frontLayer = MLPlaybackLayerSettings(
        visible: true,
        slot: 0,
        horizontalOffset: -0.24,
        heightOffset: 0.32
    )
    var middleLayer = MLPlaybackLayerSettings(
        visible: true,
        slot: 0,
        horizontalOffset: 0,
        heightOffset: 0
    )
    var finalLayer = MLPlaybackLayerSettings(
        visible: true,
        slot: 0,
        horizontalOffset: 0.24,
        heightOffset: -0.32
    )

    var surfaceCount: Int {
        switch surfaceSelectionMode {
        case .frontMiddleFinal:
            return selectedLayerSurfaces.count
        case .all:
            return 15
        }
    }

    var selectedLayerSurfaces: [MLPlaybackSurfaceSelection] {
        var selections: [MLPlaybackSurfaceSelection] = []
        if frontLayer.visible {
            selections.append(MLPlaybackSurfaceSelection(layer: 0, slot: frontLayer.slot))
        }
        if middleLayer.visible {
            selections.append(MLPlaybackSurfaceSelection(layer: 1, slot: middleLayer.slot))
        }
        if finalLayer.visible {
            selections.append(MLPlaybackSurfaceSelection(layer: 2, slot: finalLayer.slot))
        }
        return selections
    }
}

struct MLPlaybackSurfaceSelection: Equatable, Hashable {
    var layer: Int
    var slot: Int
}

struct LeaderCommunicationLogEntry: Identifiable, Equatable {
    let id: UUID
    let recordedAt: String
    let firstTargetIndex: Int
    let interactionCount: Int
    let workItemStart: UInt64
    let workItemCount: UInt64

    init(
        id: UUID = UUID(),
        recordedAt: String,
        firstTargetIndex: Int,
        interactionCount: Int,
        workItemStart: UInt64,
        workItemCount: UInt64
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.firstTargetIndex = firstTargetIndex
        self.interactionCount = interactionCount
        self.workItemStart = workItemStart
        self.workItemCount = workItemCount
    }
}

struct SimulationPerformanceMetrics: Equatable {
    var memoryUsedBytes: UInt64 = 0
    var averageFPS: Double = 0
    var averageUPS: Double = 0
    var leaderInteractionsPerSecond: Double = 0
    var sampleWindowSeconds: Double = 3.0
}

enum ViewportCameraMode: String, Codable, CaseIterable, Equatable, Sendable {
    case navigation
    case orbit

    var title: String {
        switch self {
        case .navigation:
            return "Nav"
        case .orbit:
            return "Orbit"
        }
    }
}

struct ViewportCameraState: Codable, Equatable, Sendable {
    var positionX: Float = Self.defaultPosition.x
    var positionY: Float = Self.defaultPosition.y
    var positionZ: Float = Self.defaultPosition.z
    var yaw: Float = Self.defaultYaw
    var pitch: Float = Self.defaultPitch
    var movementSpeed: Float = 1.0
    var mode: ViewportCameraMode = .navigation

    static let defaultYaw: Float = 0.75
    static let defaultPitch: Float = 0.45
    static let defaultRadius: Float = 2.45
    static let defaultMovementSpeed: Float = 1.0
    static let defaultPosition = SIMD3<Float>(
        cosf(defaultPitch) * sinf(defaultYaw) * defaultRadius,
        cosf(defaultPitch) * cosf(defaultYaw) * defaultRadius,
        sinf(defaultPitch) * defaultRadius
    )

    private enum CodingKeys: String, CodingKey {
        case positionX
        case positionY
        case positionZ
        case yaw
        case pitch
        case movementSpeed
        case mode

        // Legacy orbit-only camera payload.
        case radius
    }

    init() {}

    var position: SIMD3<Float> {
        get { SIMD3<Float>(positionX, positionY, positionZ) }
        set {
            positionX = newValue.x
            positionY = newValue.y
            positionZ = newValue.z
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        yaw = try container.decodeIfPresent(Float.self, forKey: .yaw) ?? Self.defaultYaw
        pitch = try container.decodeIfPresent(Float.self, forKey: .pitch) ?? Self.defaultPitch
        movementSpeed = try container.decodeIfPresent(Float.self, forKey: .movementSpeed) ?? Self.defaultMovementSpeed
        mode = try container.decodeIfPresent(ViewportCameraMode.self, forKey: .mode) ?? .navigation

        if let positionX = try container.decodeIfPresent(Float.self, forKey: .positionX),
           let positionY = try container.decodeIfPresent(Float.self, forKey: .positionY),
           let positionZ = try container.decodeIfPresent(Float.self, forKey: .positionZ) {
            self.positionX = positionX
            self.positionY = positionY
            self.positionZ = positionZ
        } else {
            let radius = try container.decodeIfPresent(Float.self, forKey: .radius) ?? Self.defaultRadius
            self.positionX = cosf(pitch) * sinf(yaw) * radius
            self.positionY = cosf(pitch) * cosf(yaw) * radius
            self.positionZ = sinf(pitch) * radius
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(positionX, forKey: .positionX)
        try container.encode(positionY, forKey: .positionY)
        try container.encode(positionZ, forKey: .positionZ)
        try container.encode(yaw, forKey: .yaw)
        try container.encode(pitch, forKey: .pitch)
        try container.encode(movementSpeed, forKey: .movementSpeed)
        try container.encode(mode, forKey: .mode)
    }
}
