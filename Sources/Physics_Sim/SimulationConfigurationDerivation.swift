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
            showLeaderCommunicationLog: editorState.optimizationState.showLeaderCommunicationLog
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

        var issues: [RuntimeValidationIssue] = []

        issues.append(contentsOf: moduleAssignmentIssues(editorState: editorState, availableFiles: availableFiles))

        if editorState.physicsState.particleCount < 1 {
            issues.append(
                RuntimeValidationIssue(
                    field: .particleCount,
                    message: "Particle count must be at least 1."
                )
            )
        }

        if editorState.physicsState.particleCount > SimulationParticleLimits.engineCap {
            issues.append(
                RuntimeValidationIssue(
                    field: .particleCount,
                    message: "Particle count exceeds the engine limit of \(SimulationParticleLimits.engineCap.formatted())."
                )
            )
        }

        if let issue = ModuleCompatibility.incompatibilityReason(for: activeModules, state: simulationState) {
            issues.append(RuntimeValidationIssue(field: nil, message: issue))
        }

        if editorState.optimizationState.showLeaderCommunicationLog,
           !activeModules.optimization.supportsLeaderCommunicationLog {
            issues.append(
                RuntimeValidationIssue(
                    field: nil,
                    message: "Leader communication log is not available with optimization module \(activeModules.optimization.name)."
                )
            )
        }

        issues.append(
            contentsOf: DefaultOptimizationModuleRuntime.validationIssues(
                activeModules: activeModules,
                editorState: editorState
            )
        )

        return RuntimeValidationReport(issues: issues, projectedBytes: projectedBytes)
    }

    private static func moduleAssignmentIssues(
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> [RuntimeValidationIssue] {
        ModuleKind.allCases.compactMap { kind in
            guard let assignedPath = editorState.assignedModulePaths[kind.rawValue] else { return nil }
            guard let file = resolvedAssignedModuleFile(for: kind, assignedPath: assignedPath, availableFiles: availableFiles) else {
                return RuntimeValidationIssue(
                    field: .assignedModule(kind),
                    message: "\(kind.displayName) assignment is missing in this checkout: \(URL(fileURLWithPath: assignedPath).lastPathComponent)."
                )
            }
            guard let descriptor = file.descriptor else {
                return RuntimeValidationIssue(
                    field: .assignedModule(kind),
                    message: "\(kind.displayName) assignment could not be read: \(file.url.lastPathComponent)."
                )
            }
            guard ModuleCatalog.knownModulesByName[descriptor.name] != nil else {
                return RuntimeValidationIssue(
                    field: .assignedModule(kind),
                    message: "\(kind.displayName) assignment is not supported by this build: \(descriptor.name)."
                )
            }
            return nil
        }
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
            && resolveModule(for: .optimization, editorState: editorState, availableFiles: availableFiles).providesOptimizationDebugInfo
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
