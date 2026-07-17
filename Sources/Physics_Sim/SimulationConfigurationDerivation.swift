import Foundation
import simd

enum SimulationConfigurationDerivation {
    private static let fixedGridProjectedMemorySafetyLimitBytes: UInt64 = 256 * 1024 * 1024

    static func resolvedRuntimeConfiguration(
        editorState: SimulationEditorState,
        transportState: SimulationTransportState,
        availableBundles: [ModuleBundle]
    ) -> ResolvedRuntimeConfiguration {
        let activeModules = activeModules(
            editorState: editorState,
            availableBundles: availableBundles
        )
        let simulationState = simulationState(
            transportState: transportState,
            editorState: editorState,
            activeModules: activeModules,
            availableBundles: availableBundles
        )
        let projectedBytes = projectedMemoryBytes(
            editorState: editorState,
            activeModules: activeModules
        )
        let validationReport = validationReport(
            editorState: editorState,
            simulationState: simulationState,
            activeModules: activeModules,
            projectedBytes: projectedBytes,
            availableBundles: availableBundles
        )

        return ResolvedRuntimeConfiguration(
            simulationState: simulationState,
            activeModules: activeModules,
            validationReport: validationReport
        )
    }

    static func simulationState(
        transportState: SimulationTransportState,
        editorState: SimulationEditorState,
        activeModules: ActiveModuleSet,
        availableBundles: [ModuleBundle]
    ) -> SimulationViewportState {
        let clampedTimeScale = activeModules.timeScaleProfile.clamped(editorState.physicsState.timeScale)
        let setup = ModuleSimulationSetupResolver.resolve(
            editorState: editorState,
            activeModules: activeModules
        )
        return SimulationViewportState(
            transportState: transportState,
            particleCount: setup.particleCount,
            randomDistribution: setup.randomDistribution,
            particleTypes: setup.particleTypes,
            allParticlesIntercommunicate: setup.allParticlesIntercommunicate,
            movementDirection: SIMD3<Float>(
                Float(editorState.physicsState.movementDirection.x),
                Float(editorState.physicsState.movementDirection.y),
                Float(editorState.physicsState.movementDirection.z)
            ),
            timeScale: Float(clampedTimeScale),
            sphereSize: Float(editorState.visualState.sphereSize),
            spectrumOffset: Float(editorState.visualState.spectrumOffset),
            showOptimizationInfo: visualSupportsOptimizationDebug(
                editorState: editorState,
                availableBundles: availableBundles
            ) && editorState.visualState.showOptimizationInfo,
            showLeaderCommunicationLog: editorState.optimizationState.showLeaderCommunicationLog,
            playbackRate: Float(max(0, clampedTimeScale)),
            playbackLooping: editorState.playbackState.looping,
            fixedGridSubdivisions: max(1, editorState.optimizationState.fixedGridSubdivisions),
            fixedGridSubspaceCap: max(
                1,
                min(
                    max(1, editorState.optimizationState.fixedGridSubspaceCap),
                    max(1, editorState.optimizationState.fixedGridSubdivisions)
                )
            ),
            fixedGridNeighborReadMode: editorState.optimizationState.fixedGridNeighborReadMode
        )
    }

    static func activeModules(
        editorState: SimulationEditorState,
        availableBundles: [ModuleBundle]
    ) -> ActiveModuleSet {
        ActiveModuleSet(
            physics: resolveModule(for: .physics, editorState: editorState, availableBundles: availableBundles),
            visual: resolveModule(for: .visual, editorState: editorState, availableBundles: availableBundles),
            optimization: resolveModule(for: .optimization, editorState: editorState, availableBundles: availableBundles)
        )
    }

    static func validationReport(
        editorState: SimulationEditorState,
        transportState: SimulationTransportState,
        availableBundles: [ModuleBundle]
    ) -> RuntimeValidationReport {
        resolvedRuntimeConfiguration(
            editorState: editorState,
            transportState: transportState,
            availableBundles: availableBundles
        ).validationReport
    }

    private static func validationReport(
        editorState: SimulationEditorState,
        simulationState: SimulationViewportState,
        activeModules: ActiveModuleSet,
        projectedBytes: UInt64,
        availableBundles: [ModuleBundle]
    ) -> RuntimeValidationReport {
        var issues: [RuntimeValidationIssue] = []

        issues.append(contentsOf: moduleAssignmentIssues(editorState: editorState, availableBundles: availableBundles))

        if simulationState.particleCount < 1 {
            issues.append(
                RuntimeValidationIssue(
                    field: .particleCount,
                    message: "Particle count must be at least 1."
                )
            )
        }

        if simulationState.particleCount > SimulationParticleLimits.engineCap {
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

        if activeModules.optimization.name == FixedGridOptimizationModuleRuntime.moduleName {
            let topologyBytes = FixedGridOptimizationModuleRuntime.projectedTopologyBytes(
                settings: FixedGridOptimizationSettings(
                    subdivisions: editorState.optimizationState.fixedGridSubdivisions,
                    subspaceCap: editorState.optimizationState.fixedGridSubspaceCap
                )
            )
            if topologyBytes > fixedGridProjectedMemorySafetyLimitBytes {
                issues.append(
                    RuntimeValidationIssue(
                        field: .moduleSetting(moduleName: FixedGridOptimizationModuleRuntime.moduleName, key: "Subdivisions"),
                        message: "Fixed-grid topology is too large to start safely with the current subdivisions and subspace cap."
                    )
                )
            }
        }

        issues.append(
            contentsOf: DefaultOptimizationModuleRuntime.validationIssues(
                activeModules: activeModules,
                particleCount: simulationState.particleCount
            )
        )

        return RuntimeValidationReport(issues: issues, projectedBytes: projectedBytes)
    }

    private static func moduleAssignmentIssues(
        editorState: SimulationEditorState,
        availableBundles: [ModuleBundle]
    ) -> [RuntimeValidationIssue] {
        ModuleKind.allCases.compactMap { kind in
            guard let assignedModuleID = editorState.assignedModuleIDs[kind.rawValue] else { return nil }
            guard let bundle = resolvedAssignedModuleBundle(for: kind, assignedModuleID: assignedModuleID, availableBundles: availableBundles) else {
                return RuntimeValidationIssue(
                    field: .assignedModule(kind),
                    message: "\(kind.displayName) assignment is missing in this checkout: \(assignedModuleID)."
                )
            }
            guard let descriptor = bundle.descriptor else {
                return RuntimeValidationIssue(
                    field: .assignedModule(kind),
                    message: "\(kind.displayName) assignment could not be read: \(bundle.manifestURL.lastPathComponent)."
                )
            }
            if let issue = ModuleCompatibility.runtimeSupportIncompatibilityReason(for: descriptor) {
                return RuntimeValidationIssue(
                    field: .assignedModule(kind),
                    message: issue
                )
            }
            return nil
        }
    }

    static func projectedMemoryBytes(
        editorState: SimulationEditorState,
        availableBundles: [ModuleBundle]
    ) -> UInt64 {
        projectedMemoryBytes(
            editorState: editorState,
            activeModules: activeModules(editorState: editorState, availableBundles: availableBundles)
        )
    }

    static func projectedMemoryBytes(
        editorState: SimulationEditorState,
        activeModules modules: ActiveModuleSet
    ) -> UInt64 {
        let setup = ModuleSimulationSetupResolver.resolve(
            editorState: editorState,
            activeModules: modules
        )
        let particleCount = max(1, setup.particleCount)
        let baseParticleStride = 40
        let visualStride = 16
        let optimizationStride = 16
        let typeBudget = 32 * 32
        let debugBudget = editorState.optimizationState.showLeaderCommunicationLog ? 8 * 1024 * 1024 : 0
        var reserved = UInt64(particleCount * (baseParticleStride + visualStride + optimizationStride) + typeBudget + debugBudget)
        if modules.optimization.name == FixedGridOptimizationModuleRuntime.moduleName {
            reserved += FixedGridOptimizationModuleRuntime.projectedTopologyBytes(
                settings: FixedGridOptimizationSettings(
                    subdivisions: editorState.optimizationState.fixedGridSubdivisions,
                    subspaceCap: editorState.optimizationState.fixedGridSubspaceCap
                )
            )
            if editorState.optimizationState.fixedGridNeighborReadMode == .scratch {
                reserved += FixedGridOptimizationModuleRuntime.projectedScratchBytes(particleCount: particleCount)
            }
        }
        return reserved
    }

    static func visualSupportsOptimizationDebug(
        editorState: SimulationEditorState,
        availableBundles: [ModuleBundle]
    ) -> Bool {
        resolveModule(for: .visual, editorState: editorState, availableBundles: availableBundles).acceptsOptimizationDebugInfo
            && resolveModule(for: .optimization, editorState: editorState, availableBundles: availableBundles).providesOptimizationDebugInfo
    }

    static func resolveModule(
        for kind: ModuleKind,
        editorState: SimulationEditorState,
        availableBundles: [ModuleBundle]
    ) -> ModuleDescriptor {
        guard let moduleID = editorState.assignedModuleIDs[kind.rawValue] else {
            return ModuleCatalog.fallback(for: kind.rawValue)
        }

        guard let bundle = resolvedAssignedModuleBundle(for: kind, assignedModuleID: moduleID, availableBundles: availableBundles),
              let descriptor = bundle.descriptor,
              descriptor.kind == kind.rawValue else {
            return ModuleCatalog.fallback(for: kind.rawValue)
        }

        return descriptor
    }

    static func resolvedAssignedModuleBundle(
        for kind: ModuleKind,
        assignedModuleID: String,
        availableBundles: [ModuleBundle]
    ) -> ModuleBundle? {
        if let exact = availableBundles.first(where: { $0.kind == kind && $0.id == assignedModuleID && $0.descriptor?.kind == kind.rawValue }) {
            return exact
        }

        let legacyURL = URL(fileURLWithPath: assignedModuleID)
        if legacyURL.isFileURL,
           let pathMatch = availableBundles.first(where: { $0.kind == kind && $0.manifestURL == legacyURL && $0.descriptor?.kind == kind.rawValue }) {
            return pathMatch
        }

        let legacyManifestName = legacyURL.lastPathComponent
        if let filenameMatch = availableBundles.first(where: { $0.kind == kind && $0.manifestURL.lastPathComponent == legacyManifestName && $0.descriptor?.kind == kind.rawValue }) {
            return filenameMatch
        }

        if kind == .optimization, legacyManifestName == "uniform_grid.module.json" {
            return availableBundles.first {
                $0.kind == kind && $0.descriptor?.name == FixedGridOptimizationModuleRuntime.moduleName
            }
        }

        return nil
    }
}
