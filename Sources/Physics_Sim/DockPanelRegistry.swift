import SwiftUI

struct DockPanelType: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    var id: String { rawValue }

    var title: String {
        DockPanelRegistry.definition(for: self)?.title ?? DockPanelRegistry.humanizedTitle(for: rawValue)
    }

    var subtype: DockPanelSubtype {
        DockPanelRegistry.definition(for: self)?.subtype ?? .unsorted
    }

    static let moduleSlots: Self = "moduleSlots"
    static let physicsSettings: Self = "physicsSettings"
    static let visualSettings: Self = "visualSettings"
    static let optimizationSettings: Self = "optimizationSettings"
    static let moduleCatalog: Self = "moduleCatalog"
    static let inspector: Self = "inspector"
    static let leaderCommunicationLog: Self = "leaderCommunicationLog"
    static let debugSettings: Self = "debugSettings"
}

enum DockPanelSubtype: String, CaseIterable, Identifiable {
    case core
    case diagnostics
    case debug
    case unsorted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: return "Core"
        case .diagnostics: return "Diagnostics"
        case .debug: return "Debug"
        case .unsorted: return "Unsorted"
        }
    }
}

struct DockPanelRenderContext {
    let panel: DockPanel
    let editorSettingsStore: MainWindowEditorSettingsStore
    let moduleCatalogStore: MainWindowModuleCatalogStore
    let chromeStateStore: MainWindowChromeStateStore
    let physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    let runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    let diagnosticsStore: MainWindowDiagnosticsStore
    let debugSettingsStore: MainWindowDebugSettingsStore
    let interactionSnapshotRecorder: InteractionSnapshotRecorder
    let performanceReviewLogger: PerformanceReviewLogger
    let particleCountUICap: Int
    let particleCountEngineCap: Int
    let importerTargetKind: Binding<ModuleKind>
    let isImporterPresented: Binding<Bool>
    let startInteractionSnapshotRecording: () -> Void
}

struct DockPanelDefinition {
    let type: DockPanelType
    let title: String
    let subtype: DockPanelSubtype
    let defaultZone: DockZone?
    let makeBody: @MainActor (DockPanelRenderContext) -> AnyView
}

enum DockPanelRegistry {
    static let definitions: [DockPanelDefinition] = [
        DockPanelDefinition(
            type: .moduleSlots,
            title: "Module Slots",
            subtype: .core,
            defaultZone: .left
        ) { context in
            AnyView(
                ModuleSlotsPanel(
                    editorSettingsStore: context.editorSettingsStore,
                    moduleCatalogStore: context.moduleCatalogStore,
                    chromeStateStore: context.chromeStateStore,
                    importerTargetKind: context.importerTargetKind,
                    isImporterPresented: context.isImporterPresented
                )
            )
        },
        DockPanelDefinition(
            type: .physicsSettings,
            title: "Physics Settings",
            subtype: .core,
            defaultZone: .right
        ) { context in
            AnyView(
                ModuleSettingsPanelView(
                    kind: .physics,
                    editorSettingsStore: context.editorSettingsStore,
                    physicsModuleSettingsStore: context.physicsModuleSettingsStore,
                    moduleCatalogStore: context.moduleCatalogStore,
                    runtimeConfigCoordinator: context.runtimeConfigCoordinator,
                    particleCountUICap: context.particleCountUICap,
                    particleCountEngineCap: context.particleCountEngineCap
                )
            )
        },
        DockPanelDefinition(
            type: .visualSettings,
            title: "Visual Settings",
            subtype: .core,
            defaultZone: .right
        ) { context in
            AnyView(
                ModuleSettingsPanelView(
                    kind: .visual,
                    editorSettingsStore: context.editorSettingsStore,
                    physicsModuleSettingsStore: context.physicsModuleSettingsStore,
                    moduleCatalogStore: context.moduleCatalogStore,
                    runtimeConfigCoordinator: context.runtimeConfigCoordinator,
                    particleCountUICap: context.particleCountUICap,
                    particleCountEngineCap: context.particleCountEngineCap
                )
            )
        },
        DockPanelDefinition(
            type: .optimizationSettings,
            title: "Optimization Settings",
            subtype: .core,
            defaultZone: .right
        ) { context in
            AnyView(
                ModuleSettingsPanelView(
                    kind: .optimization,
                    editorSettingsStore: context.editorSettingsStore,
                    physicsModuleSettingsStore: context.physicsModuleSettingsStore,
                    moduleCatalogStore: context.moduleCatalogStore,
                    runtimeConfigCoordinator: context.runtimeConfigCoordinator,
                    particleCountUICap: context.particleCountUICap,
                    particleCountEngineCap: context.particleCountEngineCap
                )
            )
        },
        DockPanelDefinition(
            type: .moduleCatalog,
            title: "Module Catalog",
            subtype: .core,
            defaultZone: nil
        ) { context in
            AnyView(
                ModuleCatalogPanel(
                    editorSettingsStore: context.editorSettingsStore,
                    moduleCatalogStore: context.moduleCatalogStore,
                    chromeStateStore: context.chromeStateStore
                )
            )
        },
        DockPanelDefinition(
            type: .inspector,
            title: "Debug Inspector",
            subtype: .diagnostics,
            defaultZone: .center
        ) { context in
            AnyView(
                InspectorPanel(
                    interactionSnapshotRecorder: context.interactionSnapshotRecorder,
                    performanceReviewLogger: context.performanceReviewLogger,
                    runtimeConfigCoordinator: context.runtimeConfigCoordinator,
                    diagnosticsStore: context.diagnosticsStore,
                    chromeStateStore: context.chromeStateStore,
                    onStartInteractionSnapshot: context.startInteractionSnapshotRecording,
                    onSetPerformanceReviewLoggingEnabled: { context.performanceReviewLogger.setEnabled($0) }
                )
            )
        },
        DockPanelDefinition(
            type: .leaderCommunicationLog,
            title: "Leader Communication Log",
            subtype: .diagnostics,
            defaultZone: nil
        ) { context in
            AnyView(LeaderCommunicationLogPanel(diagnosticsStore: context.diagnosticsStore))
        },
        DockPanelDefinition(
            type: .debugSettings,
            title: "Debug Settings",
            subtype: .debug,
            defaultZone: .center
        ) { context in
            AnyView(DebugSettingsPanel(debugSettingsStore: context.debugSettingsStore))
        },
    ]

    static let orderedSubtypes: [DockPanelSubtype] = DockPanelSubtype.allCases.filter { subtype in
        definitions.contains { $0.subtype == subtype }
    }

    static let defaultPanels: [DockPanel] = definitions.compactMap { definition in
        guard let zone = definition.defaultZone else { return nil }
        return DockPanel(id: UUID(), type: definition.type, zone: zone)
    }

    private static let definitionsByType: [DockPanelType: DockPanelDefinition] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.type, $0) }
    )

    static func definition(for type: DockPanelType) -> DockPanelDefinition? {
        definitionsByType[type]
    }

    static func definitions(for subtype: DockPanelSubtype) -> [DockPanelDefinition] {
        definitions.filter { $0.subtype == subtype }
    }

    static func humanizedTitle(for rawValue: String) -> String {
        let spaced = rawValue.unicodeScalars.reduce(into: "") { partial, scalar in
            let character = Character(scalar)
            if scalar.properties.isUppercase, !partial.isEmpty {
                partial.append(" ")
            }
            partial.append(character)
        }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
