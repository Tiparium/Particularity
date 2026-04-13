import Foundation
import simd

enum SimulationConfigurationDerivation {
    private static let fixedGridProjectedMemorySafetyLimitBytes: UInt64 = 256 * 1024 * 1024
    private static let totalProjectedMemorySafetyLimitBytes: UInt64 = 512 * 1024 * 1024

    static func simulationState(
        transportState: SimulationTransportState,
        editorState: SimulationEditorState,
        availableFiles: [ModuleFile]
    ) -> SimulationViewportState {
        let modules = activeModules(
            editorState: editorState,
            availableFiles: availableFiles
        )
        let isPlaybackVisualModule = modules.visual.moduleFamilyID == MLPlaybackModuleFamily.id
            && modules.visual.name == MLPlaybackModuleFamily.visualModuleName

        return SimulationViewportState(
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
            mlPlaybackRecipe: isPlaybackVisualModule ? editorState.visualState.mlPlaybackRecipe : .typeSpectrum,
            mlPlaybackNormalizationMode: isPlaybackVisualModule
                ? editorState.visualState.mlPlaybackNormalizationMode
                : .global,
            isPlaybackVisualModule: isPlaybackVisualModule,
            playbackTimeScale: Float(max(0.01, editorState.physicsState.timeScale)),
            playbackInterpolationEnabled: editorState.playbackSettings.interpolationEnabled,
            playbackSurfaceMeshEnabled: isPlaybackVisualModule && editorState.visualState.playbackSurfaceMeshEnabled,
            playbackSurfaceSmoothing: isPlaybackVisualModule
                ? Float(min(max(0, editorState.visualState.playbackSurfaceSmoothing), 1))
                : 0,
            playbackFrontLayerVisible: isPlaybackVisualModule ? editorState.visualState.playbackFrontLayerVisible : false,
            playbackMiddleLayerVisible: isPlaybackVisualModule ? editorState.visualState.playbackMiddleLayerVisible : false,
            playbackFinalLayerVisible: isPlaybackVisualModule ? editorState.visualState.playbackFinalLayerVisible : false,
            playbackFrontLayerSlot: isPlaybackVisualModule ? min(max(0, editorState.visualState.playbackFrontLayerSlot), 4) : 0,
            playbackMiddleLayerSlot: isPlaybackVisualModule ? min(max(0, editorState.visualState.playbackMiddleLayerSlot), 4) : 0,
            playbackFinalLayerSlot: isPlaybackVisualModule ? min(max(0, editorState.visualState.playbackFinalLayerSlot), 4) : 0,
            playbackFrontLayerOffset: isPlaybackVisualModule
                ? Float(min(max(-1.5, editorState.visualState.playbackFrontLayerOffset), 1.5))
                : 0,
            playbackMiddleLayerOffset: isPlaybackVisualModule
                ? Float(min(max(-1.5, editorState.visualState.playbackMiddleLayerOffset), 1.5))
                : 0,
            playbackFinalLayerOffset: isPlaybackVisualModule
                ? Float(min(max(-1.5, editorState.visualState.playbackFinalLayerOffset), 1.5))
                : 0,
            showLeaderCommunicationLog: editorState.optimizationState.showLeaderCommunicationLog,
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
        let projectedBytes = projectedMemoryBytes(
            editorState: editorState,
            activeModules: activeModules
        )

        if let issue = ModuleCompatibility.incompatibilityReason(for: activeModules, state: simulationState) {
            return RuntimeValidationReport(issue: issue, projectedBytes: projectedBytes)
        }

        if editorState.physicsState.particleCount > SimulationParticleLimits.engineCap {
            return RuntimeValidationReport(
                issue: "Particle count exceeds the hard engine cap of \(SimulationParticleLimits.engineCap.formatted()).",
                projectedBytes: projectedBytes
            )
        }

        if editorState.optimizationState.showLeaderCommunicationLog,
           !activeModules.optimization.supportsLeaderCommunicationLog {
            return RuntimeValidationReport(
                issue: "Leader communication log is not available with optimization module \(activeModules.optimization.name).",
                projectedBytes: projectedBytes
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
                return RuntimeValidationReport(
                    issue: "Fixed-grid topology is too large to start safely with the current subdivisions and subspace cap.",
                    projectedBytes: projectedBytes
                )
            }
        }

        if projectedBytes > totalProjectedMemorySafetyLimitBytes {
            return RuntimeValidationReport(
                issue: "Projected runtime memory is too high to start safely with the current configuration.",
                projectedBytes: projectedBytes
            )
        }

        return RuntimeValidationReport(issue: nil, projectedBytes: projectedBytes)
    }

    static func projectedMemoryBytes(editorState: SimulationEditorState) -> UInt64 {
        projectedMemoryBytes(
            editorState: editorState,
            activeModules: activeModules(
                editorState: editorState,
                availableFiles: []
            )
        )
    }

    static func projectedMemoryBytes(
        editorState: SimulationEditorState,
        activeModules: ActiveModuleSet
    ) -> UInt64 {
        let particleCount = max(1, editorState.physicsState.particleCount)
        let baseParticleStride = 40
        let visualStride = 16
        let optimizationStride = 16
        let typeBudget = 32 * 32
        let debugBudget = editorState.optimizationState.showLeaderCommunicationLog ? 8 * 1024 * 1024 : 0
        var reserved = UInt64(particleCount * (baseParticleStride + visualStride + optimizationStride) + typeBudget + debugBudget)

        if activeModules.optimization.name == FixedGridOptimizationModuleRuntime.moduleName {
            reserved += FixedGridOptimizationModuleRuntime.projectedTopologyBytes(
                settings: FixedGridOptimizationSettings(
                    subdivisions: editorState.optimizationState.fixedGridSubdivisions,
                    subspaceCap: editorState.optimizationState.fixedGridSubspaceCap
                )
            )
            if editorState.optimizationState.fixedGridNeighborReadMode == .scratch {
                reserved += FixedGridOptimizationModuleRuntime.projectedScratchBytes(
                    particleCount: particleCount
                )
            }
        }

        return reserved
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
              let descriptor = file.descriptor,
              descriptor.kind == kind.rawValue else {
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
        if let exact = availableFiles.first(where: { $0.kind == kind && $0.url == assignedURL && $0.descriptor?.kind == kind.rawValue }) {
            return exact
        }

        // Support module-folder migrations by matching the manifest filename when the
        // stored absolute path is stale but the module package kept the same manifest name.
        let manifestName = assignedURL.lastPathComponent
        if let filenameMatch = availableFiles.first(where: { $0.kind == kind && $0.url.lastPathComponent == manifestName && $0.descriptor?.kind == kind.rawValue }) {
            return filenameMatch
        }

        if kind == .optimization, manifestName == "uniform_grid.module.json" {
            return availableFiles.first {
                $0.kind == kind && $0.descriptor?.name == FixedGridOptimizationModuleRuntime.moduleName
            }
        }

        return nil
    }
}
