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

struct PhysicsModuleState {
    var particleCount: Int = 20_000
    var randomDistribution = true
    var particleTypes: Int = 6
    var allParticlesIntercommunicate = true
    var movementDirection = SIMD3<Double>(0.82, 0.18, 0.12)
    var timeScale: Double = 1.0
}

enum TimeScaleControlMapping {
    static let sliderRange: ClosedRange<Double> = 0...2
    static let textEntryRange: ClosedRange<Double> = 0...16
    static let sliderStep: Double = 0.01

    private static let runtimeScalePerControlUnit: Double = 0.25

    static func controlValue(forRuntimeScale runtimeScale: Double) -> Double {
        max(0, runtimeScale / runtimeScalePerControlUnit)
    }

    static func runtimeScale(forControlValue controlValue: Double) -> Double {
        max(0, controlValue * runtimeScalePerControlUnit)
    }
}

struct VisualModuleState {
    var sphereSize: Double = 0.008
    var spectrumOffset: Double = 0.0
    var showOptimizationInfo = false
}

struct OptimizationModuleState {
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

struct DebugSettingsState {
    var protectLeaderFromUnload = true
}

struct PlaybackModuleState {
    var playbackRate: Double = 1.0
    var looping = true
}

enum ModuleKind: String, CaseIterable, Identifiable, Hashable {
    case physics
    case visual
    case optimization

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .physics: return "Physics Module"
        case .visual: return "Visual Module"
        case .optimization: return "Optimization Module"
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

struct SimulationEditorState {
    var physicsState = PhysicsModuleState()
    var visualState = VisualModuleState()
    var optimizationState = OptimizationModuleState()
    var playbackState = PlaybackModuleState()
    var debugSettings = DebugSettingsState()
    var assignedModuleIDs: [String: String] = [:]
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
        entryPoints: ModuleEntryPoints = ModuleEntryPoints()
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
        entryPoints: ModuleEntryPoints? = nil
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
            entryPoints: entryPoints ?? self.entryPoints
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
    }
}

enum ModuleCatalog {
    static let toyPlaybackFamilyID = "particularity.playback.family.toy_v1"
    static let toyPlaybackSourceContract = "particularity.playback.toy_source.v1"
    static let toyPlaybackParticleSurfaceContract = "particularity.presentation.toy_particle_surface.v1"

    static let defaultPhysics = ModuleDescriptor(
        moduleID: "internal.realtime.processor.default_physics_slide_loop",
        kind: "physics",
        name: "DefaultPhysicsSlideLoop",
        visibility: .production,
        isDefaultFallback: true,
        acceptsOptimizationDebugInfo: false,
        providesOptimizationDebugInfo: false,
        supportsLeaderCommunicationLog: false
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
            supportsLeaderCommunicationLog: false
        ),
        "TypeMatrixLocalAttractionRepulsion": ModuleDescriptor(
            moduleID: "particularity.realtime.processor.type_matrix_local",
            kind: "physics",
            name: "TypeMatrixLocalAttractionRepulsion",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false
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
            pipelineStage: .processor
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
    var fixedGridSubdivisions: Int
    var fixedGridSubspaceCap: Int
    var fixedGridNeighborReadMode: FixedGridNeighborReadMode
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
        sinf(defaultPitch) * defaultRadius,
        cosf(defaultPitch) * cosf(defaultYaw) * defaultRadius
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
            self.positionY = sinf(pitch) * radius
            self.positionZ = cosf(pitch) * cosf(yaw) * radius
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
