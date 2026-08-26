import SwiftUI

struct PrimordialSoupLifecycleSettingsPanel: View {
    @ObservedObject var store: MainWindowEditorSettingsStore
    @ObservedObject var physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    let setupModuleID: String

    @State private var runtimeExpanded = true
    @State private var interactionScalingExpanded = false
    @State private var motionTuningExpanded = false
    @State private var correctiveExpanded = false
    @State private var behaviorSpaceExpanded = false
    @State private var advancedGenerationExpanded = false

    private var settings: PrimordialSoupLifecycleSettings {
        physicsModuleSettingsStore.primordialSoupLifecycleSettings()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExpandableSettingsSection(title: "Runtime Settings", isExpanded: $runtimeExpanded, accessory: { EmptyView() }) {
                runtimeSettings
            }

            ExpandableSettingsSection(title: "Behavior Space Settings", isExpanded: $behaviorSpaceExpanded, accessory: {
                if settings.hasPendingBehaviorSpaceChanges {
                    Text("Pending")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }) {
                behaviorSpaceSettings
            }
        }
    }

    private var runtimeSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            EventuallyAppliedIntSlider(
                title: "Particle Capacity",
                field: .particleCount,
                appliedValue: particleCapacityBinding,
                range: 1...SimulationParticleLimits.settingsUICap,
                helpText: "Maximum particle buffer size for this behavior space run."
            )
            EventuallyAppliedSlider(
                title: "Initial Population",
                appliedValue: settingBinding(\.initialPopulationPercent),
                range: 0.01...1.0,
                step: 0.01,
                valueText: { String(format: "%.0f%%", $0 * 100) }
            )
            EventuallyAppliedToggle(
                title: "Random Distribution",
                appliedValue: settingBinding(\.randomDistribution)
            )

            ExpandableSettingsSection(title: "Interaction Scaling", isExpanded: $interactionScalingExpanded, accessory: { EmptyView() }) {
                multiplierSlider("Inner Radius", \.innerRadiusMultiplier)
                multiplierSlider("Middle Radius", \.middleRadiusMultiplier)
                multiplierSlider("Outer Radius", \.outerRadiusMultiplier)
                multiplierSlider("Attraction", \.attractionMultiplier, range: 0...PrimordialSoupLifecycleSettings.interactionMultiplierUICap)
                multiplierSlider("Repulsion", \.repulsionMultiplier, range: 0...PrimordialSoupLifecycleSettings.interactionMultiplierUICap)
            }

            ExpandableSettingsSection(title: "Motion Tuning", isExpanded: $motionTuningExpanded, accessory: { EmptyView() }) {
                behaviorControlRow(
                    title: "Velocity Damping",
                    enabled: \.dampingEnabled,
                    value: \.dampingStrength,
                    range: 0...TypeMatrixLocalPhysicsSettings.dampingStrengthUICap,
                    defaultAction: resetDampingToDefault
                )
                behaviorControlRow(
                    title: "Momentum Blend",
                    enabled: \.momentumEnabled,
                    value: \.momentumStrength,
                    range: 0...TypeMatrixLocalPhysicsSettings.momentumStrengthUICap,
                    defaultAction: resetMomentumToDefault
                )
                behaviorControlRow(
                    title: "Speed Limit",
                    enabled: \.speedLimitEnabled,
                    value: \.speedLimit,
                    range: 0...TypeMatrixLocalPhysicsSettings.speedLimitUICap,
                    step: 0.05,
                    defaultAction: resetSpeedLimitToDefault
                )
            }

            ExpandableSettingsSection(title: "Corrective Behaviors", isExpanded: $correctiveExpanded, accessory: { EmptyView() }) {
                EventuallyAppliedToggle(title: "Teleportation Escape", appliedValue: settingBinding(\.teleportationEnabled))
                EventuallyAppliedIntSlider(
                    title: "General Interaction Budget",
                    appliedValue: settingBinding(\.teleportationGeneralInteractionBudget),
                    range: 0...TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetSliderCap,
                    textEntryRange: 0...TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetHardCap
                )
                EventuallyAppliedToggle(
                    title: "Link Self-Type Budget To General",
                    appliedValue: settingBinding(\.teleportationSelfInteractionBudgetLinked)
                )
                EventuallyAppliedIntSlider(
                    title: "Self-Type Interaction Budget",
                    appliedValue: settingBinding(\.teleportationSelfInteractionBudget),
                    range: 0...TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetSliderCap,
                    textEntryRange: 0...TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetHardCap
                )
                .disabled(settings.teleportationSelfInteractionBudgetLinked)
                EventuallyAppliedSlider(
                    title: "Teleport Accumulation",
                    appliedValue: settingBinding(\.teleportationAccumulation),
                    range: 0...TypeMatrixLocalPhysicsSettings.teleportationAccumulationUICap,
                    step: 0.01,
                    valueText: { String(format: "%.2f", $0) }
                )
                EventuallyAppliedSlider(
                    title: "Teleport Recovery",
                    appliedValue: settingBinding(\.teleportationRecoveryRate),
                    range: 0...TypeMatrixLocalPhysicsSettings.teleportationRecoveryUICap,
                    step: 0.01,
                    valueText: { String(format: "%.2f", $0) }
                )
                EventuallyAppliedSlider(
                    title: "Teleport Minimum Distance",
                    appliedValue: settingBinding(\.teleportationMinimumDistanceCentimeters),
                    range: 0...TypeMatrixLocalPhysicsSettings.teleportationMinimumDistanceUICapCentimeters,
                    step: 1,
                    valueText: { String(format: "%.0f cm", $0) }
                )
            }
        }
    }

    private var behaviorSpaceSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.hasPendingBehaviorSpaceChanges {
                pendingWarning(prominent: true)
            }
            LabeledContent("Active Type Count", value: "\(settings.activeTypeCount)")
                .font(.caption)
            EventuallyAppliedIntSlider(
                title: "Type Count",
                appliedValue: generationIntBinding(\.typeCount),
                range: 1...PrimordialSoupLifecycleSettings.maxParticleTypes,
                tickBehavior: .visible
            )
            generationPercentSlider("Stability", \.stability)
            generationPercentSlider("Complexity", \.complexity)
            generationPercentSlider("Interaction Complexity", \.forceComplexity)

            HStack {
                Button("Generate Space") {
                    physicsModuleSettingsStore.regeneratePrimordialSoupLifecycleBehaviorSpace()
                }
                .buttonStyle(AppFramedButtonStyle(.prominent))
                Button("Defaults") {
                    physicsModuleSettingsStore.restorePrimordialSoupLifecycleDefaults()
                }
                .buttonStyle(AppFramedButtonStyle())
            }

            HStack {
                Button("Restore Current") {
                    physicsModuleSettingsStore.restorePrimordialSoupLifecycleFromActiveSpace()
                }
                .buttonStyle(AppFramedButtonStyle())
                Button("Save Copy") {
                    physicsModuleSettingsStore.savePrimordialSoupLifecycleWorkingCopy()
                }
                .buttonStyle(AppFramedButtonStyle())
                Button("Load Latest") {
                    physicsModuleSettingsStore.loadLatestPrimordialSoupLifecycleSavedSpace()
                }
                .buttonStyle(AppFramedButtonStyle())
                .disabled(settings.savedBehaviorSpaces.isEmpty)
            }

            Text("Saved spaces: \(settings.savedBehaviorSpaces.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ExpandableSettingsSection(title: "Advanced Generation Ranges", isExpanded: $advancedGenerationExpanded, accessory: { EmptyView() }) {
                Text("v0.1 Interaction Foundation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                rangeEditor("Signed Force", \.signedForceRange, range: -8...8)
                rangeEditor("Inner Radius", \.innerRadiusRangeCentimeters, range: 0.5...12, suffix: "cm")
                rangeEditor("Middle Radius", \.middleRadiusRangeCentimeters, range: 0...12, suffix: "cm")
                rangeEditor("Outer Radius", \.outerRadiusRangeCentimeters, range: 0...16, suffix: "cm")

                Divider()

                Text("v0.2 Lifecycle Additions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("All On") {
                        setFeatureGates(.allEnabled)
                    }
                    .buttonStyle(AppFramedButtonStyle())
                    Button("All Off") {
                        setFeatureGates(.v01Baseline)
                    }
                    .buttonStyle(AppFramedButtonStyle())
                }
                rangeEditor("Energy Cost", \.energyCostRange, enabled: \.energyCostEnabled, range: -1...1)
                rangeEditor("Threat Contribution", \.threatContributionRange, enabled: \.threatContributionEnabled, range: 0...4)
                rangeEditor("Max Speed", \.maxSpeedRange, enabled: \.maxSpeedEnabled, range: 0.1...12)
                rangeEditor("Motility", \.motilityRange, enabled: \.motilityEnabled, range: 0...0.25, displayScale: 1000, suffix: "x1000")
                rangeEditor("Energy Decay", \.energyDecayRange, enabled: \.energyDecayEnabled, range: 0...0.08, displayScale: 1000, suffix: "x1000")
                rangeEditor("Reproduction Threshold", \.reproductionThresholdRange, enabled: \.reproductionThresholdEnabled, range: 0...4)
                rangeEditor("Reproduction Cost", \.reproductionCostRange, enabled: \.reproductionCostEnabled, range: 0...4)
                rangeEditor("Child Energy Fraction", \.childEnergyFractionRange, enabled: \.childEnergyFractionEnabled, range: 0...1)
                rangeEditor("Reproduction Cooldown", \.reproductionCooldownRange, enabled: \.reproductionCooldownEnabled, range: 0...2)
                rangeEditor("Threat Sensitivity", \.threatSensitivityRange, enabled: \.threatSensitivityEnabled, range: 0...4)
            }
        }
    }

    private var particleCapacityBinding: Binding<Int> {
        Binding(
            get: {
                let value = store.moduleSetting(
                    moduleID: setupModuleID,
                    settingID: ModuleSimulationSetupSettingID.particleCount,
                    defaultValue: .number(Double(PrimordialSoupLifecycleSettings.particleCapacityDefault))
                ).numberValue ?? Double(PrimordialSoupLifecycleSettings.particleCapacityDefault)
                return min(max(1, Int(value.rounded())), SimulationParticleLimits.settingsUICap)
            },
            set: {
                store.setModuleSetting(
                    moduleID: setupModuleID,
                    settingID: ModuleSimulationSetupSettingID.particleCount,
                    value: .number(Double($0))
                )
            }
        )
    }

    private func pendingWarning(prominent: Bool) -> some View {
        Text("Behavior-space settings have pending changes. Generate a new space to apply them.")
            .font(prominent ? .caption.weight(.semibold) : .caption2)
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func multiplierSlider(
        _ title: String,
        _ keyPath: WritableKeyPath<PrimordialSoupLifecycleSettings, Double>,
        range: ClosedRange<Double> = PrimordialSoupLifecycleSettings.radiusMultiplierRange
    ) -> some View {
        EventuallyAppliedSlider(
            title: title,
            appliedValue: settingBinding(keyPath),
            range: range,
            step: 0.05,
            valueText: { String(format: "%.2fx", $0) }
        )
    }

    private func generationPercentSlider(
        _ title: String,
        _ keyPath: WritableKeyPath<PrimordialSoupLifecycleGenerationSettings, Double>
    ) -> some View {
        EventuallyAppliedSlider(
            title: title,
            appliedValue: generationBinding(keyPath),
            range: 0...1,
            step: 0.01,
            valueText: { String(format: "%.0f%%", $0 * 100) }
        )
    }

    private func rangeEditor(
        _ title: String,
        _ keyPath: WritableKeyPath<PrimordialSoupLifecycleGenerationSettings, PrimordialSoupLifecycleRange>,
        range: ClosedRange<Double>,
        displayScale: Double = 1,
        suffix: String = ""
    ) -> some View {
        EventuallyAppliedRangeSlider(
            title: title,
            lowerValue: generationRangeBinding(keyPath, \.minimum),
            upperValue: generationRangeBinding(keyPath, \.maximum),
            range: range,
            step: 0.1 / max(displayScale, 1),
            displayScale: displayScale,
            suffix: suffix
        )
    }

    private func rangeEditor(
        _ title: String,
        _ keyPath: WritableKeyPath<PrimordialSoupLifecycleGenerationSettings, PrimordialSoupLifecycleRange>,
        enabled enabledKeyPath: WritableKeyPath<PrimordialSoupLifecycleFeatureGates, Bool>,
        range: ClosedRange<Double>,
        displayScale: Double = 1,
        suffix: String = ""
    ) -> some View {
        let enabled = settings.featureGates[keyPath: enabledKeyPath]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AppCheckboxToggle(isOn: featureGateBinding(enabledKeyPath))
                Text("Use \(title)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(enabled ? .primary : .secondary)
                Spacer()
            }
            EventuallyAppliedRangeSlider(
                title: title,
                lowerValue: generationRangeBinding(keyPath, \.minimum),
                upperValue: generationRangeBinding(keyPath, \.maximum),
                range: range,
                step: 0.1 / max(displayScale, 1),
                displayScale: displayScale,
                suffix: suffix
            )
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        }
    }

    private func behaviorControlRow(
        title: String,
        enabled enabledKeyPath: WritableKeyPath<PrimordialSoupLifecycleSettings, Bool>,
        value valueKeyPath: WritableKeyPath<PrimordialSoupLifecycleSettings, Double>,
        range: ClosedRange<Double>,
        step: Double = 0.01,
        defaultAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                AppCheckboxToggle(isOn: settingBinding(enabledKeyPath))
                Button("Default", action: defaultAction)
                    .buttonStyle(AppFramedButtonStyle())
                    .controlSize(.small)
            }
            EventuallyAppliedSlider(
                title: "Strength",
                appliedValue: settingBinding(valueKeyPath),
                range: range,
                step: step,
                valueText: { String(format: "%.2f", $0) }
            )
            .disabled(!settings[keyPath: enabledKeyPath])
        }
    }

    private func settingBinding<Value>(
        _ keyPath: WritableKeyPath<PrimordialSoupLifecycleSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                var next = settings
                next[keyPath: keyPath] = $0
                physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
            }
        )
    }

    private func setFeatureGates(_ featureGates: PrimordialSoupLifecycleFeatureGates) {
        var next = settings
        next.featureGates = featureGates
        physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
    }

    private func featureGateBinding(
        _ keyPath: WritableKeyPath<PrimordialSoupLifecycleFeatureGates, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settings.featureGates[keyPath: keyPath] },
            set: {
                var next = settings
                next.featureGates[keyPath: keyPath] = $0
                physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
            }
        )
    }

    private func generationBinding(
        _ keyPath: WritableKeyPath<PrimordialSoupLifecycleGenerationSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { settings.pendingGenerationSettings[keyPath: keyPath] },
            set: {
                var next = settings
                next.pendingGenerationSettings[keyPath: keyPath] = $0
                physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
            }
        )
    }

    private func generationIntBinding(
        _ keyPath: WritableKeyPath<PrimordialSoupLifecycleGenerationSettings, Int>
    ) -> Binding<Int> {
        Binding(
            get: { settings.pendingGenerationSettings[keyPath: keyPath] },
            set: {
                var next = settings
                next.pendingGenerationSettings[keyPath: keyPath] = $0
                physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
            }
        )
    }

    private func generationRangeBinding(
        _ rangeKeyPath: WritableKeyPath<PrimordialSoupLifecycleGenerationSettings, PrimordialSoupLifecycleRange>,
        _ valueKeyPath: WritableKeyPath<PrimordialSoupLifecycleRange, Double>
    ) -> Binding<Double> {
        Binding(
            get: { settings.pendingGenerationSettings[keyPath: rangeKeyPath][keyPath: valueKeyPath] },
            set: {
                var next = settings
                next.pendingGenerationSettings[keyPath: rangeKeyPath][keyPath: valueKeyPath] = $0
                physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
            }
        )
    }

    private func resetDampingToDefault() {
        var next = settings
        next.dampingEnabled = true
        next.dampingStrength = TypeMatrixLocalPhysicsSettings.dampingStrengthDefault
        physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
    }

    private func resetMomentumToDefault() {
        var next = settings
        next.momentumEnabled = true
        next.momentumStrength = TypeMatrixLocalPhysicsSettings.momentumStrengthDefault
        physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
    }

    private func resetSpeedLimitToDefault() {
        var next = settings
        next.speedLimitEnabled = true
        next.speedLimit = TypeMatrixLocalPhysicsSettings.speedLimitDefault
        physicsModuleSettingsStore.setPrimordialSoupLifecycleSettings(next)
    }
}
