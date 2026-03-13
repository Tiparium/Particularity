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

enum MemoryBudgetPreset: String, CaseIterable, Identifiable {
    case m1
    case m1Pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m1:
            return "M1"
        case .m1Pro:
            return "M1 Pro"
        }
    }

    var budgetBytes: UInt64 {
        switch self {
        case .m1:
            return 4 * 1024 * 1024 * 1024
        case .m1Pro:
            return 24 * 1024 * 1024 * 1024
        }
    }
}

struct PhysicsModuleState {
    var particleCount: Int = 20_000
    var randomDistribution = true
    var particleTypes: Int = 6
    var movementDirection = SIMD3<Double>(0.82, 0.18, 0.12)
    var timeScale: Double = 1.0
}

struct VisualModuleState {
    var sphereSize: Double = 0.025
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

struct SimulationViewportState: Equatable {
    var transportState: SimulationTransportState
    var particleCount: Int
    var randomDistribution: Bool
    var particleTypes: Int
    var movementDirection: SIMD3<Float>
    var timeScale: Float
    var sphereSize: Float
    var spectrumOffset: Float
    var showOptimizationInfo: Bool
    var optimizationBlockingMode: OptimizationBlockingMode
}

struct SimulationPerformanceMetrics: Equatable {
    var memoryUsedBytes: UInt64 = 0
    var averageFPS: Double = 0
    var averageUPS: Double = 0
    var leaderInteractionsPerSecond: Double = 0
    var sampleWindowSeconds: Double = 3.0
}

struct ViewportCameraState: Equatable {
    var yaw: Float = 0.75
    var pitch: Float = 0.45
}
