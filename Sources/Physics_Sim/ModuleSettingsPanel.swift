import AppKit
import SwiftUI

struct ModuleSettingsPanelView: View {
    let kind: ModuleKind
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore
    @ObservedObject var physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    @ObservedObject var moduleCatalogStore: MainWindowModuleCatalogStore
    @ObservedObject var runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator

    private var transportState: SimulationTransportState {
        runtimeConfigCoordinator.transportState
    }

    private var resolved: ModuleDescriptor {
        switch kind {
        case .physics:
            return runtimeConfigCoordinator.activeModules.physics
        case .visual:
            return runtimeConfigCoordinator.activeModules.visual
        case .optimization:
            return runtimeConfigCoordinator.activeModules.optimization
        }
    }

    private var resolvedBundle: ModuleBundle? {
        moduleCatalogStore.availableBundles.first {
            $0.id == resolved.moduleID || $0.descriptor?.moduleID == resolved.moduleID
        }
    }

    private var schema: ModuleSettingsSchema? {
        resolvedBundle?.manifest?.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let schema, !schema.sections.isEmpty {
                GenericModuleSettingsSchemaView(
                    module: resolved,
                    schema: schema,
                    editorSettingsStore: editorSettingsStore
                )
            } else {
                builtInSettingsPanel
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(resolved.name)
                    .font(.caption.weight(.semibold))
                Text("\(EditorViewSupport.roleTitle(for: resolved)) Module")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if resolved.visibility == .dev {
                Text("DEV")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var builtInSettingsPanel: some View {
        switch kind {
        case .physics:
            if resolved.name == ModuleCatalog.defaultPhysics.name {
                PhysicsSettingsPanel(
                    store: editorSettingsStore,
                    setupProfile: runtimeConfigCoordinator.activeModules.simulationSetupProfile,
                    setupModuleID: runtimeConfigCoordinator.activeModules.physics.moduleID
                )
            } else if resolved.name == TypeMatrixLocalPhysicsSettings.moduleName {
                TypeMatrixLocalPhysicsModuleSettingsPanel(
                    store: editorSettingsStore,
                    physicsModuleSettingsStore: physicsModuleSettingsStore,
                    transportState: transportState,
                    setupProfile: runtimeConfigCoordinator.activeModules.simulationSetupProfile,
                    setupModuleID: runtimeConfigCoordinator.activeModules.physics.moduleID
                )
            } else {
                unavailable
            }
        case .visual:
            if resolved.name == ModuleCatalog.defaultVisual.name {
                VisualSettingsPanel(
                    store: editorSettingsStore,
                    optimizationDebugSupported: runtimeConfigCoordinator.activeModules.visual.acceptsOptimizationDebugInfo
                        && runtimeConfigCoordinator.activeModules.optimization.providesOptimizationDebugInfo
                )
            } else {
                unavailable
            }
        case .optimization:
            if resolved.name == ModuleCatalog.defaultOptimization.name
                || resolved.name == FixedGridOptimizationModuleRuntime.moduleName {
                OptimizationSettingsPanel(store: editorSettingsStore, resolvedOptimization: resolved)
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This module does not expose settings yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Resolved module: \(resolved.name)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct GenericModuleSettingsSchemaView: View {
    let module: ModuleDescriptor
    let schema: ModuleSettingsSchema
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(schema.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    if let title = section.title, !title.isEmpty {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(section.controls) { control in
                        controlView(control)
                    }
                }
            }
        }
        .id(module.moduleID)
        .animation(.easeInOut(duration: 0.22), value: module.moduleID)
    }

    @ViewBuilder
    private func controlView(_ control: ModuleSettingControl) -> some View {
        switch control.type {
        case .toggle:
            EventuallyAppliedToggle(
                title: control.title,
                field: .moduleSetting(moduleName: module.name, key: control.id),
                appliedValue: boolBinding(for: control)
            )
            if let helpText = control.helpText {
                Text(helpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .slider:
            EventuallyAppliedSlider(
                title: control.title,
                field: .moduleSetting(moduleName: module.name, key: control.id),
                appliedValue: numberBinding(for: control),
                range: (control.minimum ?? 0)...(control.maximum ?? 1),
                step: control.step ?? 0.01,
                valueText: { String(format: "%.2f", $0) }
            )
        case .intSlider:
            EventuallyAppliedIntSlider(
                title: control.title,
                field: .moduleSetting(moduleName: module.name, key: control.id),
                appliedValue: intBinding(for: control),
                range: Int(control.minimum ?? 0)...Int(control.maximum ?? 100),
                helpText: control.helpText
            )
        case .segmented:
            VStack(alignment: .leading, spacing: 4) {
                Text(control.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(control.title, selection: textBinding(for: control)) {
                    ForEach(control.options) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                if let helpText = control.helpText {
                    Text(helpText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(control.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(control.title, text: textBinding(for: control))
                    .textFieldStyle(.roundedBorder)
                if let helpText = control.helpText {
                    Text(helpText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .color:
            ModuleColorSettingControl(
                title: control.title,
                value: textBinding(for: control),
                helpText: control.helpText
            )
        }
    }

    private func boolBinding(for control: ModuleSettingControl) -> Binding<Bool> {
        Binding(
            get: {
                editorSettingsStore.moduleSetting(
                    moduleID: module.moduleID,
                    settingID: control.id,
                    defaultValue: control.defaultValue
                ).boolValue ?? control.defaultValue.boolValue ?? false
            },
            set: {
                editorSettingsStore.setModuleSetting(
                    moduleID: module.moduleID,
                    settingID: control.id,
                    value: .bool($0)
                )
            }
        )
    }

    private func numberBinding(for control: ModuleSettingControl) -> Binding<Double> {
        Binding(
            get: {
                editorSettingsStore.moduleSetting(
                    moduleID: module.moduleID,
                    settingID: control.id,
                    defaultValue: control.defaultValue
                ).numberValue ?? control.defaultValue.numberValue ?? 0
            },
            set: {
                editorSettingsStore.setModuleSetting(
                    moduleID: module.moduleID,
                    settingID: control.id,
                    value: .number($0)
                )
            }
        )
    }

    private func intBinding(for control: ModuleSettingControl) -> Binding<Int> {
        Binding(
            get: { Int(numberBinding(for: control).wrappedValue.rounded()) },
            set: { numberBinding(for: control).wrappedValue = Double($0) }
        )
    }

    private func textBinding(for control: ModuleSettingControl) -> Binding<String> {
        Binding(
            get: {
                editorSettingsStore.moduleSetting(
                    moduleID: module.moduleID,
                    settingID: control.id,
                    defaultValue: control.defaultValue
                ).textValue ?? control.defaultValue.textValue ?? ""
            },
            set: {
                editorSettingsStore.setModuleSetting(
                    moduleID: module.moduleID,
                    settingID: control.id,
                    value: .text($0)
                )
            }
        )
    }
}

/// A schema-driven color field for module-owned visual settings.
struct ModuleColorSettingControl: View {
    let title: String
    @Binding var value: String
    let helpText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ColorPicker(title, selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                TextField("#RRGGBB", text: $value)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 84)
                    .onSubmit { value = Self.hex(for: Self.color(from: value)) }
            }
            if let helpText {
                Text(helpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Self.color(from: value) },
            set: { value = Self.hex(for: $0) }
        )
    }

    private static func color(from hex: String) -> Color {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt64(digits, radix: 16) else { return .white }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private static func hex(for color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int((nsColor.redComponent * 255).rounded()),
            Int((nsColor.greenComponent * 255).rounded()),
            Int((nsColor.blueComponent * 255).rounded())
        )
    }
}

private struct PhysicsSettingsPanel: View {
    @ObservedObject var store: MainWindowEditorSettingsStore
    let setupProfile: ModuleSimulationSetupProfile
    let setupModuleID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SimulationSetupControlsView(store: store, profile: setupProfile, moduleID: setupModuleID)
            Picker("Movement", selection: .constant("slide")) {
                Text("Slide").tag("slide")
            }
            .font(.caption)
            .pickerStyle(.segmented)
            .disabled(true)
            ForEach([("Direction X", \SIMD3<Double>.x), ("Direction Y", \SIMD3<Double>.y), ("Direction Z", \SIMD3<Double>.z)], id: \.0) { title, keyPath in
                EventuallyAppliedSlider(
                    title: title,
                    field: .moduleSetting(moduleName: ModuleCatalog.defaultPhysics.name, key: title),
                    appliedValue: Binding(
                        get: { store.editorState.physicsState.movementDirection[keyPath: keyPath] },
                        set: {
                            var next = store.editorState.physicsState
                            next.movementDirection[keyPath: keyPath] = $0
                            store.setPhysicsState(next)
                        }
                    ),
                    range: 0...1,
                    step: 0.01,
                    valueText: { String(format: "%.2f", $0) }
                )
            }
        }
    }
}

struct SimulationSetupControlsView: View {
    @ObservedObject var store: MainWindowEditorSettingsStore
    let profile: ModuleSimulationSetupProfile
    let moduleID: String

    var body: some View {
        if profile.exposesAnyControl {
            VStack(alignment: .leading, spacing: 6) {
                if let particleCount = profile.particleCount {
                    EventuallyAppliedIntSlider(
                        title: "Particle Count",
                        field: .particleCount,
                        appliedValue: Binding(
                            get: {
                                setupIntValue(
                                    ModuleSimulationSetupSettingID.particleCount,
                                    range: particleCount.range,
                                    migrationFallback: store.editorState.physicsState.particleCount,
                                    defaultValue: particleCount.defaultValue
                                )
                            },
                            set: {
                                setSetupNumber(
                                    ModuleSimulationSetupSettingID.particleCount,
                                    value: min(max(particleCount.range.lowerBound, $0), particleCount.range.upperBound)
                                )
                            }
                        ),
                        range: particleCount.range,
                        helpText: particleCount.helpText
                    )
                }

                if profile.randomDistribution != nil {
                    EventuallyAppliedToggle(title: "Random Distribution", field: .randomDistribution, appliedValue: Binding(
                        get: {
                            setupBoolValue(
                                ModuleSimulationSetupSettingID.randomDistribution,
                                migrationFallback: store.editorState.physicsState.randomDistribution,
                                defaultValue: profile.randomDistribution?.defaultValue ?? true
                            )
                        },
                        set: { setSetupBool(ModuleSimulationSetupSettingID.randomDistribution, value: $0) }
                    ))
                }

                if profile.interParticleCommunication != nil {
                    EventuallyAppliedToggle(title: "Inter-Particle Communication", field: .allParticlesIntercommunicate, appliedValue: Binding(
                        get: {
                            setupBoolValue(
                                ModuleSimulationSetupSettingID.interParticleCommunication,
                                migrationFallback: store.editorState.physicsState.allParticlesIntercommunicate,
                                defaultValue: profile.interParticleCommunication?.defaultValue ?? true
                            )
                        },
                        set: { setSetupBool(ModuleSimulationSetupSettingID.interParticleCommunication, value: $0) }
                    ))
                }

                if let particleTypes = profile.particleTypes {
                    EventuallyAppliedSlider(
                        title: "Particle Types",
                        field: .particleTypes,
                        appliedValue: Binding(
                            get: {
                                Double(
                                    setupIntValue(
                                        ModuleSimulationSetupSettingID.particleTypes,
                                        range: particleTypes.range,
                                        migrationFallback: store.editorState.physicsState.particleTypes,
                                        defaultValue: particleTypes.defaultValue
                                    )
                                )
                            },
                            set: {
                                setSetupNumber(
                                    ModuleSimulationSetupSettingID.particleTypes,
                                    value: min(
                                        max(particleTypes.range.lowerBound, Int($0.rounded())),
                                        particleTypes.range.upperBound
                                    )
                                )
                            }
                        ),
                        range: Double(particleTypes.range.lowerBound)...Double(particleTypes.range.upperBound),
                        step: 1,
                        tickBehavior: .visible,
                        valueText: { "\(Int($0.rounded()))" }
                    )
                }
            }
        }
    }

    private func setupIntValue(
        _ settingID: String,
        range: ClosedRange<Int>,
        migrationFallback: Int,
        defaultValue: Int
    ) -> Int {
        let fallback = min(max(range.lowerBound, migrationFallback), range.upperBound)
        let value = store.moduleSetting(
            moduleID: moduleID,
            settingID: settingID,
            defaultValue: .number(Double(fallback == 0 ? defaultValue : fallback))
        ).numberValue ?? Double(defaultValue)
        return min(max(range.lowerBound, Int(value.rounded())), range.upperBound)
    }

    private func setupBoolValue(
        _ settingID: String,
        migrationFallback: Bool,
        defaultValue: Bool
    ) -> Bool {
        store.moduleSetting(
            moduleID: moduleID,
            settingID: settingID,
            defaultValue: .bool(migrationFallback)
        ).boolValue ?? defaultValue
    }

    private func setSetupNumber(_ settingID: String, value: Int) {
        store.setModuleSetting(moduleID: moduleID, settingID: settingID, value: .number(Double(value)))
    }

    private func setSetupBool(_ settingID: String, value: Bool) {
        store.setModuleSetting(moduleID: moduleID, settingID: settingID, value: .bool(value))
    }
}

private struct VisualSettingsPanel: View {
    @ObservedObject var store: MainWindowEditorSettingsStore
    let optimizationDebugSupported: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EventuallyAppliedSlider(
                title: "Sphere Size",
                field: .sphereSize,
                appliedValue: Binding(
                    get: { store.editorState.visualState.sphereSize },
                    set: {
                        var next = store.editorState.visualState
                        next.sphereSize = $0
                        store.setVisualState(next)
                    }
                ),
                range: 0.002...0.015,
                step: 0.0005,
                valueText: { String(format: "%.3f", $0) }
            )
            EventuallyAppliedSlider(
                title: "Spectrum Offset",
                field: .spectrumOffset,
                appliedValue: Binding(
                    get: { store.editorState.visualState.spectrumOffset },
                    set: {
                        var next = store.editorState.visualState
                        next.spectrumOffset = $0
                        store.setVisualState(next)
                    }
                ),
                range: 0...1,
                step: 0.01,
                valueText: { String(format: "%.2f", $0) }
            )
            EventuallyAppliedToggle(
                title: "Show Optimization Info",
                field: .showOptimizationInfo,
                appliedValue: Binding(
                    get: { store.editorState.visualState.showOptimizationInfo },
                    set: {
                        var next = store.editorState.visualState
                        next.showOptimizationInfo = $0
                        store.setVisualState(next)
                    }
                )
            )
            .disabled(!optimizationDebugSupported)
        }
    }
}

private struct OptimizationSettingsPanel: View {
    @ObservedObject var store: MainWindowEditorSettingsStore
    let resolvedOptimization: ModuleDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EventuallyAppliedToggle(
                title: "Leader Communication Log",
                field: .showLeaderCommunicationLog,
                appliedValue: Binding(
                    get: { store.editorState.optimizationState.showLeaderCommunicationLog },
                    set: {
                        var next = store.editorState.optimizationState
                        next.showLeaderCommunicationLog = $0
                        store.setOptimizationState(next)
                    }
                )
            )
            EventuallyAppliedToggle(
                title: "Protect Leader From Unload",
                appliedValue: Binding(
                    get: { store.editorState.debugSettings.protectLeaderFromUnload },
                    set: {
                        var next = store.editorState.debugSettings
                        next.protectLeaderFromUnload = $0
                        store.setDebugSettings(next)
                    }
                )
            )

            if resolvedOptimization.name == FixedGridOptimizationModuleRuntime.moduleName {
                EventuallyAppliedIntSlider(
                    title: "Subdivisions",
                    field: .moduleSetting(moduleName: FixedGridOptimizationModuleRuntime.moduleName, key: "Subdivisions"),
                    appliedValue: Binding(
                        get: { store.editorState.optimizationState.fixedGridSubdivisions },
                        set: {
                            var next = store.editorState.optimizationState
                            next.fixedGridSubdivisions = min(FixedGridOptimizationModuleRuntime.maxSubdivisions, max(1, $0))
                            next.fixedGridSubspaceCap = min(next.fixedGridSubspaceCap, next.fixedGridSubdivisions)
                            store.setOptimizationState(next)
                        }
                    ),
                    range: 1...FixedGridOptimizationModuleRuntime.maxSubdivisions
                )

                EventuallyAppliedIntSlider(
                    title: "Subspace Cap",
                    field: .moduleSetting(moduleName: FixedGridOptimizationModuleRuntime.moduleName, key: "Subspace Cap"),
                    appliedValue: Binding(
                        get: {
                            min(
                                store.editorState.optimizationState.fixedGridSubspaceCap,
                                store.editorState.optimizationState.fixedGridSubdivisions
                            )
                        },
                        set: {
                            var next = store.editorState.optimizationState
                            next.fixedGridSubspaceCap = min(max(1, $0), next.fixedGridSubdivisions)
                            store.setOptimizationState(next)
                        }
                    ),
                    range: 1...max(1, store.editorState.optimizationState.fixedGridSubdivisions)
                )

                EventuallyAppliedSegmentedPicker(
                    title: "Neighbor Read Mode",
                    field: .moduleSetting(moduleName: FixedGridOptimizationModuleRuntime.moduleName, key: "Neighbor Read Mode"),
                    appliedValue: Binding(
                        get: { store.editorState.optimizationState.fixedGridNeighborReadMode },
                        set: {
                            var next = store.editorState.optimizationState
                            next.fixedGridNeighborReadMode = $0
                            store.setOptimizationState(next)
                        }
                    ),
                    options: FixedGridNeighborReadMode.allCases,
                    optionTitle: { $0.title }
                )

                Text("Wrapped fixed-grid traversal publishes multi-range candidate spans.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Naive all-pairs traversal is the default optimization MVP.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
