import Foundation
import simd

enum SimulationConfigurationDerivation {
    static func simulationState(
        transportState: SimulationTransportState,
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> SimulationViewportState {
        SimulationViewportState(
            transportState: transportState,
            particleCount: editorState.physicsState.particleCount,
            randomDistribution: editorState.physicsState.randomDistribution,
            particleTypes: editorState.physicsState.particleTypes,
            allParticlesIntercommunicate: editorState.physicsState.allParticlesIntercommunicate,
            movementDirection: SIMD3<Float>(
                Float(editorState.physicsState.movementDirection.x),
                Float(editorState.physicsState.movementDirection.y),
                Float(editorState.physicsState.movementDirection.z)
            ),
            timeScale: Float(editorState.physicsState.timeScale),
            sphereSize: Float(editorState.visualState.sphereSize),
            spectrumOffset: Float(editorState.visualState.spectrumOffset),
            showOptimizationInfo: visualSupportsOptimizationDebug(
                editorState: editorState,
                availableFiles: availableFiles
            ) && editorState.visualState.showOptimizationInfo,
            showLeaderCommunicationLog: editorState.optimizationState.showLeaderCommunicationLog,
            optimizationBlockingMode: editorState.optimizationState.blockingMode
        )
    }

    static func activeModules(
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> ActiveModuleSet {
        ActiveModuleSet(
            physics: resolveModule(for: .physics, editorState: editorState, availableFiles: availableFiles),
            visual: resolveModule(for: .visual, editorState: editorState, availableFiles: availableFiles),
            optimization: resolveModule(for: .optimization, editorState: editorState, availableFiles: availableFiles)
        )
    }

    static func validationReport(
        editorState: SimulationEditorState,
        transportState: SimulationTransportState,
        availableFiles: [ModuleFile]
    ) -> RuntimeValidationReport {
        let simulationState = simulationState(
            transportState: transportState,
            editorState: editorState,
            availableFiles: availableFiles
        )
        let activeModules = activeModules(
            editorState: editorState,
            availableFiles: availableFiles
        )
        let projectedBytes = projectedMemoryBytes(editorState: editorState)

        if let issue = ModuleCompatibility.incompatibilityReason(for: activeModules, state: simulationState) {
            return RuntimeValidationReport(issue: issue, projectedBytes: projectedBytes)
        }

        if editorState.optimizationState.showLeaderCommunicationLog,
           activeModules.optimization.name != ModuleCatalog.defaultOptimization.name {
            return RuntimeValidationReport(
                issue: "Leader communication log is only available with \(ModuleCatalog.defaultOptimization.name).",
                projectedBytes: projectedBytes
            )
        }

        return RuntimeValidationReport(issue: nil, projectedBytes: projectedBytes)
    }

    static func projectedMemoryBytes(editorState: SimulationEditorState) -> UInt64 {
        let particleCount = max(1, editorState.physicsState.particleCount)
        let baseParticleStride = 40
        let visualStride = 16
        let optimizationStride = 16
        let typeBudget = 32 * 32
        let debugBudget = editorState.optimizationState.showLeaderCommunicationLog ? 8 * 1024 * 1024 : 0
        let reserved = particleCount * (baseParticleStride + visualStride + optimizationStride) + typeBudget + debugBudget
        return UInt64(reserved)
    }

    static func visualSupportsOptimizationDebug(
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> Bool {
        resolveModule(for: .visual, editorState: editorState, availableFiles: availableFiles).acceptsOptimizationDebugInfo
            && resolveModule(for: .optimization, editorState: editorState, availableFiles: availableFiles).name == ModuleCatalog.defaultOptimization.name
    }

    static func resolveModule(
        for kind: ModuleKind,
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> ModuleDescriptor {
        guard let path = editorState.assignedModulePaths[kind.rawValue] else {
            return ModuleCatalog.fallback(for: kind.rawValue)
        }

        guard let file = resolvedAssignedModuleFile(for: kind, assignedPath: path, availableFiles: availableFiles),
              let descriptor = file.descriptor else {
            return ModuleCatalog.fallback(for: kind.rawValue)
        }

        return descriptor
    }

    static func resolvedAssignedModuleFile(
        for kind: ModuleKind,
        assignedPath: String,
        availableFiles: [ModuleFile]
    ) -> ModuleFile? {
        let assignedURL = URL(fileURLWithPath: assignedPath)
        if let exact = availableFiles.first(where: { $0.kind == kind && $0.url == assignedURL }) {
            return exact
        }

        // Support module-folder migrations by matching the manifest filename when the
        // stored absolute path is stale but the module package kept the same manifest name.
        let manifestName = assignedURL.lastPathComponent
        return availableFiles.first(where: { $0.kind == kind && $0.url.lastPathComponent == manifestName })
    }
}
