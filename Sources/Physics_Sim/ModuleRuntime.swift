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

enum FixedGridNeighborReadMode: String, CaseIterable, Equatable, Sendable {
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

struct SimulationEditorState {
    var physicsState = PhysicsModuleState()
    var visualState = VisualModuleState()
    var optimizationState = OptimizationModuleState()
    var debugSettings = DebugSettingsState()
    var assignedModulePaths: [String: String] = [:]
}

struct ModuleDescriptor: Identifiable, Equatable {
    let kind: String
    let name: String
    let visibility: BuildVisibility
    let isDefaultFallback: Bool
    let acceptsOptimizationDebugInfo: Bool
    let providesOptimizationDebugInfo: Bool
    let supportsLeaderCommunicationLog: Bool
    let moduleFamilyID: String?

    init(
        kind: String,
        name: String,
        visibility: BuildVisibility,
        isDefaultFallback: Bool,
        acceptsOptimizationDebugInfo: Bool,
        providesOptimizationDebugInfo: Bool,
        supportsLeaderCommunicationLog: Bool,
        moduleFamilyID: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.visibility = visibility
        self.isDefaultFallback = isDefaultFallback
        self.acceptsOptimizationDebugInfo = acceptsOptimizationDebugInfo
        self.providesOptimizationDebugInfo = providesOptimizationDebugInfo
        self.supportsLeaderCommunicationLog = supportsLeaderCommunicationLog
        self.moduleFamilyID = moduleFamilyID
    }

    var id: String {
        "\(kind)|\(name)"
    }
}

enum ModuleCatalog {
    static let defaultPhysics = ModuleDescriptor(
        kind: "physics",
        name: "DefaultPhysicsSlideLoop",
        visibility: .production,
        isDefaultFallback: true,
        acceptsOptimizationDebugInfo: false,
        providesOptimizationDebugInfo: false,
        supportsLeaderCommunicationLog: false
    )

    static let defaultVisual = ModuleDescriptor(
        kind: "visual",
        name: "DefaultRainbowUnlitSpheres",
        visibility: .production,
        isDefaultFallback: true,
        acceptsOptimizationDebugInfo: true,
        providesOptimizationDebugInfo: false,
        supportsLeaderCommunicationLog: false
    )

    static let defaultOptimization = ModuleDescriptor(
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
            kind: "physics",
            name: PhysicsModuleTemplateRuntime.moduleName,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false
        ),
        "TypeMatrixLocalAttractionRepulsion": ModuleDescriptor(
            kind: "physics",
            name: "TypeMatrixLocalAttractionRepulsion",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false
        ),
        "DefaultGreySpheres": ModuleDescriptor(
            kind: "visual",
            name: "DefaultGreySpheres",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false
        ),
        FixedGridOptimizationModuleRuntime.moduleName: ModuleDescriptor(
            kind: "optimization",
            name: FixedGridOptimizationModuleRuntime.moduleName,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: true,
            supportsLeaderCommunicationLog: true
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
}

enum ModuleCompatibility {
    static func incompatibilityReason(for modules: ActiveModuleSet, state: SimulationViewportState) -> String? {
        if modules.hasPartialModuleFamilySelection {
            return "Playback module families must be selected as a compatible physics, visual, and optimization trio."
        }

        if state.showOptimizationInfo && !modules.visual.acceptsOptimizationDebugInfo {
            return "Visual module \(modules.visual.name) does not accept optimization debug data."
        }

        if state.showOptimizationInfo && !modules.optimization.providesOptimizationDebugInfo {
            return "Optimization module \(modules.optimization.name) does not provide optimization debug data."
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

struct ViewportCameraState: Codable, Equatable {
    var yaw: Float = 0.75
    var pitch: Float = 0.45
    var radius: Float = 3.6
}
