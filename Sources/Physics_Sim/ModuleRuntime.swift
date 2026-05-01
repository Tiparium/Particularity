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

struct VisualModuleState {
    var sphereSize: Double = 0.008
    var spectrumOffset: Double = 0.0
    var showOptimizationInfo = false
    var mlPlaybackRecipe: MLPlaybackVisualRecipe = .typeSpectrum
    var mlPlaybackNormalizationMode: MLPlaybackNormalizationMode = .global
    var playbackSurfaceMeshEnabled = true
    var playbackSurfaceSmoothing: Double = 0.35
    var playbackFrontLayerVisible = true
    var playbackMiddleLayerVisible = true
    var playbackFinalLayerVisible = true
    var playbackFrontLayerSlot = 0
    var playbackMiddleLayerSlot = 0
    var playbackFinalLayerSlot = 0
    var playbackFrontLayerHorizontalOffset: Double = -0.24
    var playbackMiddleLayerHorizontalOffset: Double = 0.0
    var playbackFinalLayerHorizontalOffset: Double = 0.24
    var playbackFrontLayerOffset: Double = 0.32
    var playbackMiddleLayerOffset: Double = 0.0
    var playbackFinalLayerOffset: Double = -0.32
}

struct OptimizationModuleState {
    var showLeaderCommunicationLog = false
    var fixedGridSubdivisions: Int = 8
    var fixedGridSubspaceCap: Int = 2
    var fixedGridNeighborReadMode: FixedGridNeighborReadMode = .scratch
}

struct PlaybackSettingsState {
    var interpolationEnabled = false
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

enum ModuleKind: String, CaseIterable, Identifiable {
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
    var playbackSettings = PlaybackSettingsState()
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

enum MLPlaybackModuleFamily {
    static let id = "ml-data-playback"
    static let physicsModuleName = "MLPlaybackFrameApplicator"
    static let visualModuleName = "MLPlaybackRecipeVisualizer"
    static let optimizationModuleName = "MLPlaybackSidecarLayout"
}

enum MLPlaybackVisualRecipe: Int, CaseIterable, Hashable, Codable {
    case typeSpectrum = 0
    case confidenceMargin = 1
    case predictionDelta = 2

    var shortTitle: String {
        switch self {
        case .typeSpectrum:
            return "Surface"
        case .confidenceMargin:
            return "Bands"
        case .predictionDelta:
            return "Focus"
        }
    }

    var title: String {
        switch self {
        case .typeSpectrum:
            return "Activation Surface"
        case .confidenceMargin:
            return "Target Bands"
        case .predictionDelta:
            return "Periodicity Focus"
        }
    }

    var detail: String {
        switch self {
        case .typeSpectrum:
            return "Primary field view. Height and color track neuron activation across the x/y grid."
        case .confidenceMargin:
            return "Highlights modular target bands so you can compare activation ridges against output classes."
        case .predictionDelta:
            return "Suppresses weak regions and emphasizes high-periodicity structure in the activation field."
        }
    }
}

enum MLPlaybackNormalizationMode: Int, CaseIterable, Hashable, Codable {
    case global = 0
    case perFrame = 1

    var shortTitle: String {
        switch self {
        case .global:
            return "Global"
        case .perFrame:
            return "Frame"
        }
    }

    var title: String {
        switch self {
        case .global:
            return "Global Range"
        case .perFrame:
            return "Per-Frame Range"
        }
    }
}

enum PlaybackLayer: String, CaseIterable, Hashable {
    case front
    case middle
    case final

    var title: String {
        switch self {
        case .front:
            return "Front Layer"
        case .middle:
            return "Middle Layer"
        case .final:
            return "Final Layer"
        }
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
        MLPlaybackModuleFamily.physicsModuleName: ModuleDescriptor(
            kind: "physics",
            name: MLPlaybackModuleFamily.physicsModuleName,
            visibility: .dev,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: MLPlaybackModuleFamily.id
        ),
        MLPlaybackModuleFamily.visualModuleName: ModuleDescriptor(
            kind: "visual",
            name: MLPlaybackModuleFamily.visualModuleName,
            visibility: .dev,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: MLPlaybackModuleFamily.id
        ),
        MLPlaybackModuleFamily.optimizationModuleName: ModuleDescriptor(
            kind: "optimization",
            name: MLPlaybackModuleFamily.optimizationModuleName,
            visibility: .dev,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            moduleFamilyID: MLPlaybackModuleFamily.id
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

struct RuntimeValidationReport {
    let issue: String?
    let projectedBytes: UInt64

    var canStart: Bool {
        issue == nil
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

    var isPlaybackModuleFamily: Bool {
        completeModuleFamilyID == MLPlaybackModuleFamily.id
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
    var mlPlaybackRecipe: MLPlaybackVisualRecipe
    var mlPlaybackNormalizationMode: MLPlaybackNormalizationMode
    var isPlaybackVisualModule: Bool
    var playbackTimeScale: Float
    var playbackInterpolationEnabled: Bool
    var playbackSurfaceMeshEnabled: Bool
    var playbackSurfaceSmoothing: Float
    var playbackFrontLayerVisible: Bool
    var playbackMiddleLayerVisible: Bool
    var playbackFinalLayerVisible: Bool
    var playbackFrontLayerSlot: Int
    var playbackMiddleLayerSlot: Int
    var playbackFinalLayerSlot: Int
    var playbackFrontLayerHorizontalOffset: Float
    var playbackMiddleLayerHorizontalOffset: Float
    var playbackFinalLayerHorizontalOffset: Float
    var playbackFrontLayerOffset: Float
    var playbackMiddleLayerOffset: Float
    var playbackFinalLayerOffset: Float
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
