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
}

enum OptimizationBlockingMode: String, CaseIterable, Identifiable {
    case nonBlocking
    case fullBlocking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nonBlocking:
            return "Non-Blocking"
        case .fullBlocking:
            return "Full Blocking"
        }
    }
}

struct OptimizationModuleState {
    var showLeaderCommunicationLog = false
    var blockingMode: OptimizationBlockingMode = .fullBlocking
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
    var debugSettings = DebugSettingsState()
    var assignedModulePaths: [String: String] = [:]
}

struct ModuleDescriptor: Identifiable, Equatable {
    let kind: String
    let name: String
    let visibility: BuildVisibility
    let isDefaultFallback: Bool
    let acceptsOptimizationDebugInfo: Bool

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
        acceptsOptimizationDebugInfo: false
    )

    static let defaultVisual = ModuleDescriptor(
        kind: "visual",
        name: "DefaultRainbowUnlitSpheres",
        visibility: .production,
        isDefaultFallback: true,
        acceptsOptimizationDebugInfo: true
    )

    static let defaultOptimization = ModuleDescriptor(
        kind: "optimization",
        name: "DefaultOptimizationAllPairs",
        visibility: .production,
        isDefaultFallback: true,
        acceptsOptimizationDebugInfo: false
    )

    static let knownModulesByName: [String: ModuleDescriptor] = [
        PhysicsModuleTemplateRuntime.moduleName: ModuleDescriptor(
            kind: "physics",
            name: PhysicsModuleTemplateRuntime.moduleName,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false
        ),
        "TypeMatrixLocalAttractionRepulsion": ModuleDescriptor(
            kind: "physics",
            name: "TypeMatrixLocalAttractionRepulsion",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false
        ),
        "DefaultGreySpheres": ModuleDescriptor(
            kind: "visual",
            name: "DefaultGreySpheres",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false
        ),
        "UniformGrid": ModuleDescriptor(
            kind: "optimization",
            name: "UniformGrid",
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false
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
}

enum ModuleCompatibility {
    static func incompatibilityReason(for modules: ActiveModuleSet, state: SimulationViewportState) -> String? {
        if modules.visual.acceptsOptimizationDebugInfo,
           modules.optimization.name != ModuleCatalog.defaultOptimization.name {
            return "Visual module \(modules.visual.name) requires optimization debug compatibility, but optimization module \(modules.optimization.name) does not provide it."
        }

        if state.showOptimizationInfo && !modules.visual.acceptsOptimizationDebugInfo {
            return "Visual module \(modules.visual.name) does not accept optimization debug data."
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
    var optimizationBlockingMode: OptimizationBlockingMode
}

struct LeaderCommunicationLogEntry: Identifiable, Equatable {
    let id: UUID
    let recordedAt: String
    let firstTargetIndex: Int
    let interactionCount: Int
    let workItemStart: UInt64
    let workItemCount: UInt64
    let blockingMode: OptimizationBlockingMode

    init(
        id: UUID = UUID(),
        recordedAt: String,
        firstTargetIndex: Int,
        interactionCount: Int,
        workItemStart: UInt64,
        workItemCount: UInt64,
        blockingMode: OptimizationBlockingMode
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.firstTargetIndex = firstTargetIndex
        self.interactionCount = interactionCount
        self.workItemStart = workItemStart
        self.workItemCount = workItemCount
        self.blockingMode = blockingMode
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
