import SwiftUI

struct TypeMatrixLocalPhysicsModuleSettingsPanel: View {
    @ObservedObject var store: MainWindowEditorSettingsStore
    @ObservedObject var physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    let transportState: SimulationTransportState
    let setupProfile: ModuleSimulationSetupProfile
    let setupModuleID: String

    private var settings: TypeMatrixLocalPhysicsSettings {
        physicsModuleSettingsStore.typeMatrixLocalSettings()
    }

    private var activeParticleTypeCount: Int {
        max(
            1,
            min(
                TypeMatrixLocalPhysicsSettings.maxParticleTypes,
                Int(
                    store.moduleSetting(
                        moduleID: setupModuleID,
                        settingID: ModuleSimulationSetupSettingID.particleTypes,
                        defaultValue: .number(Double(store.editorState.physicsState.particleTypes))
                    ).numberValue?.rounded() ?? Double(store.editorState.physicsState.particleTypes)
                )
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SimulationSetupControlsView(store: store, profile: setupProfile, moduleID: setupModuleID)
            EventuallyAppliedSlider(
                title: "Inner Radius",
                appliedValue: Binding(
                    get: { settings.innerRadiusCentimeters },
                    set: {
                        var next = settings
                        next.innerRadiusCentimeters = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: 0...TypeMatrixLocalPhysicsSettings.zoneUICapCentimeters,
                step: 0.5,
                valueText: { String(format: "%.1f cm", $0) }
            )
            EventuallyAppliedSlider(
                title: "Middle Radius",
                appliedValue: Binding(
                    get: { settings.middleRadiusCentimeters },
                    set: {
                        var next = settings
                        next.middleRadiusCentimeters = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: 0...TypeMatrixLocalPhysicsSettings.zoneUICapCentimeters,
                step: 0.5,
                valueText: { String(format: "%.1f cm", $0) }
            )
            EventuallyAppliedSlider(
                title: "Outer Radius",
                appliedValue: Binding(
                    get: { settings.outerRadiusCentimeters },
                    set: {
                        var next = settings
                        next.outerRadiusCentimeters = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: 0...TypeMatrixLocalPhysicsSettings.zoneUICapCentimeters,
                step: 0.5,
                valueText: { String(format: "%.1f cm", $0) }
            )
            EventuallyAppliedSlider(
                title: "Matrix Minimum",
                appliedValue: Binding(
                    get: { Double(settings.matrixMinimumValue) },
                    set: {
                        var next = settings
                        let proposed = Int($0.rounded())
                        next.matrixMinimumValue = min(proposed, next.matrixMaximumValue)
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: Double(-TypeMatrixLocalPhysicsSettings.matrixValueUICapMagnitude)...Double(TypeMatrixLocalPhysicsSettings.matrixValueUICapMagnitude),
                step: 1,
                tickBehavior: .visible,
                valueText: { "\(Int($0.rounded()))" }
            )
            EventuallyAppliedSlider(
                title: "Matrix Maximum",
                appliedValue: Binding(
                    get: { Double(settings.matrixMaximumValue) },
                    set: {
                        var next = settings
                        let proposed = Int($0.rounded())
                        next.matrixMaximumValue = max(proposed, next.matrixMinimumValue)
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: Double(-TypeMatrixLocalPhysicsSettings.matrixValueUICapMagnitude)...Double(TypeMatrixLocalPhysicsSettings.matrixValueUICapMagnitude),
                step: 1,
                tickBehavior: .visible,
                valueText: { "\(Int($0.rounded()))" }
            )
            EventuallyAppliedSlider(
                title: "Attraction Multiplier",
                appliedValue: Binding(
                    get: { settings.attractionMultiplier },
                    set: {
                        var next = settings
                        next.attractionMultiplier = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: 0...TypeMatrixLocalPhysicsSettings.interactionMultiplierUICap,
                step: 0.05,
                valueText: { String(format: "%.2fx", $0) }
            )
            EventuallyAppliedSlider(
                title: "Repulsion Multiplier",
                appliedValue: Binding(
                    get: { settings.repulsionMultiplier },
                    set: {
                        var next = settings
                        next.repulsionMultiplier = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: 0...TypeMatrixLocalPhysicsSettings.interactionMultiplierUICap,
                step: 0.05,
                valueText: { String(format: "%.2fx", $0) }
            )
            TypeMatrixBehaviorControlRow(
                title: "Velocity Damping",
                enabledValue: Binding(
                    get: { settings.dampingEnabled },
                    set: {
                        var next = settings
                        next.dampingEnabled = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                strengthValue: Binding(
                    get: { settings.dampingStrength },
                    set: {
                        var next = settings
                        next.dampingStrength = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: 0...TypeMatrixLocalPhysicsSettings.dampingStrengthUICap,
                step: 0.01,
                valueText: { String(format: "%.2f", $0) },
                resetToDefault: {
                    var next = settings
                    next.resetDampingToDefault()
                    physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                }
            )
            TypeMatrixBehaviorControlRow(
                title: "Momentum Blend",
                enabledValue: Binding(
                    get: { settings.momentumEnabled },
                    set: {
                        var next = settings
                        next.momentumEnabled = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                strengthValue: Binding(
                    get: { settings.momentumStrength },
                    set: {
                        var next = settings
                        next.momentumStrength = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: 0...TypeMatrixLocalPhysicsSettings.momentumStrengthUICap,
                step: 0.01,
                valueText: { String(format: "%.2f", $0) },
                resetToDefault: {
                    var next = settings
                    next.resetMomentumToDefault()
                    physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                }
            )
            TypeMatrixBehaviorControlRow(
                title: "Speed Limit",
                enabledValue: Binding(
                    get: { settings.speedLimitEnabled },
                    set: {
                        var next = settings
                        next.speedLimitEnabled = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                strengthValue: Binding(
                    get: { settings.speedLimit },
                    set: {
                        var next = settings
                        next.speedLimit = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                ),
                range: 0...TypeMatrixLocalPhysicsSettings.speedLimitUICap,
                step: 0.05,
                valueText: { String(format: "%.2f", $0) },
                resetToDefault: {
                    var next = settings
                    next.resetSpeedLimitToDefault()
                    physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                }
            )
            TypeMatrixCorrectiveBehaviorSection(
                settings: settings,
                physicsModuleSettingsStore: physicsModuleSettingsStore
            )
            EventuallyAppliedToggle(
                title: "Randomize On Simulation Start",
                appliedValue: Binding(
                    get: { settings.randomizeOnSimulationStart },
                    set: {
                        var next = settings
                        next.randomizeOnSimulationStart = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                    }
                )
            )

            Button("Regenerate Matrix") {
                physicsModuleSettingsStore.regenerateTypeMatrix()
            }
            .buttonStyle(AppFramedButtonStyle(.prominent))

            VStack(alignment: .leading, spacing: 4) {
                Text("Simulation space is treated as a 1 meter cube. Radius controls are expressed in centimeters and capped to 12 cm in the UI.")
                Text("The stored matrix below is the canonical editable matrix. If startup randomization is enabled, the running simulation uses a randomized copy on start without overwriting the stored matrix.")
                Text("While the simulation is running, matrix edits and regeneration immediately replace the active runtime matrix.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            TypeMatrixEditorPanel(
                settings: settings,
                activeParticleTypeCount: activeParticleTypeCount,
                setMatrixValue: { row, column, value in
                    physicsModuleSettingsStore.setTypeMatrixValue(row: row, column: column, value: value)
                }
            )
        }
    }
}

private struct TypeMatrixCorrectiveBehaviorSection: View {
    let settings: TypeMatrixLocalPhysicsSettings
    @ObservedObject var physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    @State private var teleportationExpanded = false
    @State private var interactionFuelExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Corrective Behaviors")
                .font(.caption.weight(.semibold))

            TypeMatrixSubBehaviorGroup(
                title: "Teleportation Escape",
                enabledValue: Binding(
                    get: { settings.teleportationEnabled },
                    set: {
                        var next = settings
                        next.teleportationEnabled = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                        if $0 { teleportationExpanded = true }
                    }
                ),
                isExpanded: $teleportationExpanded
            ) {
                EventuallyAppliedIntSlider(
                    title: "General Interaction Budget",
                    appliedValue: Binding(
                        get: { settings.teleportationGeneralInteractionBudget },
                        set: {
                            var next = settings
                            next.teleportationGeneralInteractionBudget = $0
                            if next.teleportationSelfInteractionBudgetLinked {
                                next.teleportationSelfInteractionBudget = $0
                            }
                            physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                        }
                    ),
                    range: 0...TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetSliderCap,
                    textEntryRange: 0...TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetHardCap,
                    helpText: "Slider range: 0-\(TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetSliderCap.formatted()). Manual entry can go up to \(TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetHardCap.formatted()). Only meaningful non-self interactions count toward this budget."
                )

                EventuallyAppliedToggle(
                    title: "Link Self-Type Budget To General",
                    appliedValue: Binding(
                        get: { settings.teleportationSelfInteractionBudgetLinked },
                        set: {
                            var next = settings
                            next.teleportationSelfInteractionBudgetLinked = $0
                            if $0 {
                                next.teleportationSelfInteractionBudget = next.teleportationGeneralInteractionBudget
                            }
                            physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                        }
                    )
                )

                EventuallyAppliedIntSlider(
                    title: "Self-Type Interaction Budget",
                    appliedValue: Binding(
                        get: {
                            settings.teleportationSelfInteractionBudgetLinked
                                ? settings.teleportationGeneralInteractionBudget
                                : settings.teleportationSelfInteractionBudget
                        },
                        set: {
                            var next = settings
                            next.teleportationSelfInteractionBudget = $0
                            physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                        }
                    ),
                    range: 0...TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetSliderCap,
                    textEntryRange: 0...TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetHardCap,
                    helpText: "Slider range: 0-\(TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetSliderCap.formatted()). Manual entry can go up to \(TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetHardCap.formatted()). Only same-type interactions count toward this budget."
                )
                .disabled(settings.teleportationSelfInteractionBudgetLinked)

                EventuallyAppliedSlider(
                    title: "Teleport Accumulation",
                    appliedValue: Binding(
                        get: { settings.teleportationAccumulation },
                        set: {
                            var next = settings
                            next.teleportationAccumulation = $0
                            physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                        }
                    ),
                    range: 0...TypeMatrixLocalPhysicsSettings.teleportationAccumulationUICap,
                    step: 0.01,
                    valueText: { String(format: "%.2f", $0) }
                )

                EventuallyAppliedSlider(
                    title: "Teleport Recovery",
                    appliedValue: Binding(
                        get: { settings.teleportationRecoveryRate },
                        set: {
                            var next = settings
                            next.teleportationRecoveryRate = $0
                            physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                        }
                    ),
                    range: 0...TypeMatrixLocalPhysicsSettings.teleportationRecoveryUICap,
                    step: 0.01,
                    valueText: { String(format: "%.2f", $0) }
                )

                EventuallyAppliedSlider(
                    title: "Teleport Minimum Distance",
                    appliedValue: Binding(
                        get: { settings.teleportationMinimumDistanceCentimeters },
                        set: {
                            var next = settings
                            next.teleportationMinimumDistanceCentimeters = $0
                            physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                        }
                    ),
                    range: 0...TypeMatrixLocalPhysicsSettings.teleportationMinimumDistanceUICapCentimeters,
                    step: 1,
                    valueText: { String(format: "%.0f cm", $0) }
                )
            }

            TypeMatrixSubBehaviorGroup(
                title: "Interaction Fuel",
                enabledValue: Binding(
                    get: { settings.interactionFuelEnabled },
                    set: {
                        var next = settings
                        next.interactionFuelEnabled = $0
                        physicsModuleSettingsStore.setTypeMatrixLocalSettings(next)
                        if $0 { interactionFuelExpanded = true }
                    }
                ),
                isExpanded: $interactionFuelExpanded
            ) {
                Text("Interaction fuel is only a toggle shell in this pass.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            teleportationExpanded = settings.teleportationEnabled
            interactionFuelExpanded = settings.interactionFuelEnabled
        }
    }
}

private struct TypeMatrixSubBehaviorGroup<Content: View>: View {
    let title: String
    let enabledValue: Binding<Bool>
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(
        title: String,
        enabledValue: Binding<Bool>,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.enabledValue = enabledValue
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        ExpandableSettingsSection(
            title: title,
            isExpanded: $isExpanded,
            accessory: {
                AppCheckboxToggle(isOn: enabledValue, helpText: enabledValue.wrappedValue ? "Disable \(title)" : "Enable \(title)")
            },
            content: {
                content
            }
        )
    }
}

private struct TypeMatrixBehaviorControlRow: View {
    let title: String
    let enabledValue: Binding<Bool>
    let strengthValue: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let valueText: (Double) -> String
    let resetToDefault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                AppCheckboxToggle(isOn: enabledValue, helpText: enabledValue.wrappedValue ? "Disable \(title)" : "Enable \(title)")
                Button("Default", action: resetToDefault)
                    .buttonStyle(AppFramedButtonStyle())
                    .controlSize(.small)
            }
            EventuallyAppliedSlider(
                title: "Strength",
                appliedValue: strengthValue,
                range: range,
                step: step,
                valueText: valueText
            )
            .disabled(!enabledValue.wrappedValue)
        }
        .padding(.vertical, 2)
    }
}

private struct TypeMatrixEditorPanel: View {
    let settings: TypeMatrixLocalPhysicsSettings
    let activeParticleTypeCount: Int
    let setMatrixValue: (Int, Int, Int) -> Void

    private let cellSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Interaction Matrix")
                .font(.caption.weight(.semibold))

            Text("Rows are source particle type A. Columns are target particle type B. Click a cell to cycle through the current matrix min/max range.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        TypeMatrixLabelCell(text: "A\\B", width: cellSize + 10)
                        ForEach(0..<activeParticleTypeCount, id: \.self) { column in
                            TypeMatrixLabelCell(text: "\(column)", width: cellSize)
                        }
                    }

                    ForEach(0..<activeParticleTypeCount, id: \.self) { row in
                        HStack(spacing: 4) {
                            TypeMatrixLabelCell(text: "\(row)", width: cellSize + 10)
                            ForEach(0..<activeParticleTypeCount, id: \.self) { column in
                                let index = row * TypeMatrixLocalPhysicsSettings.maxParticleTypes + column
                                let value = settings.matrixValues[index]
                                Button {
                                    setMatrixValue(row, column, nextMatrixValue(after: value))
                                } label: {
                                    Text("\(value)")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: cellSize, height: cellSize)
                                        .background(matrixCellColor(for: value), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 160, idealHeight: 220, maxHeight: 260)
            .background(.quaternary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func nextMatrixValue(after value: Int) -> Int {
        if value >= settings.matrixMaximumValue {
            return settings.matrixMinimumValue
        }
        return value + 1
    }

    private func matrixCellColor(for value: Int) -> Color {
        switch value {
        case ..<0:
            return .red.opacity(0.34 + min(0.46, Double(abs(value)) * 0.08))
        case 0:
            return .gray.opacity(0.22)
        default:
            return .green.opacity(0.28 + min(0.44, Double(value) * 0.08))
        }
    }
}

private struct TypeMatrixLabelCell: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .frame(width: width, height: 20)
            .foregroundStyle(.secondary)
    }
}
