import Foundation

struct PrimordialSoupLifecycleTypeProfile: Codable, Equatable, Sendable {
    var maxSpeed: Double
    var motility: Double
    var innerRadiusCentimeters: Double
    var middleRadiusCentimeters: Double
    var outerRadiusCentimeters: Double
    var energyDecayRate: Double
    var reproductionEnergyThreshold: Double
    var reproductionEnergyCost: Double
    var childEnergyFraction: Double
    var reproductionCooldown: Double
    var threatSensitivity: Double
}

struct PrimordialSoupLifecycleRelationship: Codable, Equatable, Sendable {
    var signedForce: Double
    var energyCost: Double
    var threatContribution: Double
}

struct PrimordialSoupLifecycleBehaviorSpace: Codable, Equatable, Sendable {
    var id: String
    var createdAt: Date
    var generationSettings: PrimordialSoupLifecycleGenerationSettings
    var typeProfiles: [PrimordialSoupLifecycleTypeProfile]
    var relationships: [PrimordialSoupLifecycleRelationship]

    var typeCount: Int {
        generationSettings.typeCount
    }
}

struct PrimordialSoupLifecycleRange: Codable, Equatable, Sendable {
    var minimum: Double
    var maximum: Double

    func clamped() -> PrimordialSoupLifecycleRange {
        var next = self
        if next.minimum > next.maximum {
            swap(&next.minimum, &next.maximum)
        }
        return next
    }

    func interpolate(_ t: Double) -> Double {
        let safe = clamped()
        return safe.minimum + (safe.maximum - safe.minimum) * min(max(t, 0), 1)
    }
}

struct PrimordialSoupLifecycleGenerationSettings: Codable, Equatable, Sendable {
    var typeCount: Int = 6
    var stability: Double = 0.65
    var complexity: Double = 0.35
    var forceComplexity: Double = 0.67
    var signedForceRange = PrimordialSoupLifecycleRange(minimum: -1, maximum: 1)
    var energyCostRange = PrimordialSoupLifecycleRange(minimum: -0.08, maximum: 0.10)
    var threatContributionRange = PrimordialSoupLifecycleRange(minimum: 0, maximum: 1)
    var maxSpeedRange = PrimordialSoupLifecycleRange(minimum: 1.2, maximum: 3.2)
    var motilityRange = PrimordialSoupLifecycleRange(minimum: 0.0, maximum: 0.006)
    var innerRadiusRangeCentimeters = PrimordialSoupLifecycleRange(minimum: 2.5, maximum: 2.5)
    var middleRadiusRangeCentimeters = PrimordialSoupLifecycleRange(minimum: 1.5, maximum: 1.5)
    var outerRadiusRangeCentimeters = PrimordialSoupLifecycleRange(minimum: 2.5, maximum: 2.5)
    var energyDecayRange = PrimordialSoupLifecycleRange(minimum: 0.002, maximum: 0.012)
    var reproductionThresholdRange = PrimordialSoupLifecycleRange(minimum: 0.65, maximum: 1.2)
    var reproductionCostRange = PrimordialSoupLifecycleRange(minimum: 0.18, maximum: 0.36)
    var childEnergyFractionRange = PrimordialSoupLifecycleRange(minimum: 0.32, maximum: 0.58)
    var reproductionCooldownRange = PrimordialSoupLifecycleRange(minimum: 0.08, maximum: 0.32)
    var threatSensitivityRange = PrimordialSoupLifecycleRange(minimum: 0.1, maximum: 1.2)
    var seed: UInt64 = 0xC0FFEE

    static let defaults = PrimordialSoupLifecycleGenerationSettings()

    func sanitized() -> PrimordialSoupLifecycleGenerationSettings {
        var next = self
        next.typeCount = min(max(1, next.typeCount), PrimordialSoupLifecycleSettings.maxParticleTypes)
        next.stability = min(max(0, next.stability), 1)
        next.complexity = min(max(0, next.complexity), 1)
        next.forceComplexity = min(max(0, next.forceComplexity), 1)
        next.signedForceRange = next.signedForceRange.clamped()
        next.energyCostRange = next.energyCostRange.clamped()
        next.threatContributionRange = next.threatContributionRange.clamped()
        next.maxSpeedRange = next.maxSpeedRange.clamped()
        next.motilityRange = next.motilityRange.clamped()
        next.innerRadiusRangeCentimeters = next.innerRadiusRangeCentimeters.clamped()
        next.middleRadiusRangeCentimeters = next.middleRadiusRangeCentimeters.clamped()
        next.outerRadiusRangeCentimeters = next.outerRadiusRangeCentimeters.clamped()
        next.energyDecayRange = next.energyDecayRange.clamped()
        next.reproductionThresholdRange = next.reproductionThresholdRange.clamped()
        next.reproductionCostRange = next.reproductionCostRange.clamped()
        next.childEnergyFractionRange = next.childEnergyFractionRange.clamped()
        next.reproductionCooldownRange = next.reproductionCooldownRange.clamped()
        next.threatSensitivityRange = next.threatSensitivityRange.clamped()
        return next
    }
}

struct PrimordialSoupLifecycleFeatureGates: Codable, Equatable, Sendable {
    var signedForceEnabled = true
    var energyCostEnabled = true
    var threatContributionEnabled = true
    var maxSpeedEnabled = true
    var motilityEnabled = true
    var innerRadiusEnabled = true
    var middleRadiusEnabled = true
    var outerRadiusEnabled = true
    var energyDecayEnabled = true
    var reproductionThresholdEnabled = true
    var reproductionCostEnabled = true
    var childEnergyFractionEnabled = true
    var reproductionCooldownEnabled = true
    var threatSensitivityEnabled = true

    static let allEnabled = PrimordialSoupLifecycleFeatureGates()

    static let v01Baseline = PrimordialSoupLifecycleFeatureGates(
        signedForceEnabled: true,
        energyCostEnabled: false,
        threatContributionEnabled: false,
        maxSpeedEnabled: false,
        motilityEnabled: false,
        innerRadiusEnabled: true,
        middleRadiusEnabled: true,
        outerRadiusEnabled: true,
        energyDecayEnabled: false,
        reproductionThresholdEnabled: false,
        reproductionCostEnabled: false,
        childEnergyFractionEnabled: false,
        reproductionCooldownEnabled: false,
        threatSensitivityEnabled: false
    )

    func sanitized() -> PrimordialSoupLifecycleFeatureGates {
        var next = self
        next.signedForceEnabled = true
        next.innerRadiusEnabled = true
        next.middleRadiusEnabled = true
        next.outerRadiusEnabled = true
        return next
    }
}

struct PrimordialSoupLifecycleSettings: Codable, Equatable, Sendable {
    static let moduleName = "PrimordialSoupLifecycleProcessor"
    static let maxParticleTypes = 32
    static let simulationCubeSideMeters = TypeMatrixLocalPhysicsSettings.simulationCubeSideMeters
    static let simulationCubeSideWorldUnits = TypeMatrixLocalPhysicsSettings.simulationCubeSideWorldUnits
    static let centimetersPerMeter = TypeMatrixLocalPhysicsSettings.centimetersPerMeter
    static let radiusMultiplierRange = 0.2...3.0
    static let interactionMultiplierUICap = TypeMatrixLocalPhysicsSettings.interactionMultiplierUICap
    static let particleCapacityDefault = 20_000

    var randomDistribution = true
    var initialPopulationPercent: Double = 0.60
    var innerRadiusMultiplier: Double = 1.0
    var middleRadiusMultiplier: Double = 1.0
    var outerRadiusMultiplier: Double = 1.0
    var attractionMultiplier: Double = 1.0
    var repulsionMultiplier: Double = 1.0
    var dampingEnabled = true
    var dampingStrength: Double = TypeMatrixLocalPhysicsSettings.dampingStrengthDefault
    var momentumEnabled = true
    var momentumStrength: Double = TypeMatrixLocalPhysicsSettings.momentumStrengthDefault
    var speedLimitEnabled = true
    var speedLimit: Double = TypeMatrixLocalPhysicsSettings.speedLimitDefault
    var teleportationEnabled = false
    var teleportationGeneralInteractionBudget: Int = 48
    var teleportationSelfInteractionBudgetLinked = true
    var teleportationSelfInteractionBudget: Int = 48
    var teleportationAccumulation: Double = 0.08
    var teleportationRecoveryRate: Double = 0.18
    var teleportationMinimumDistanceCentimeters: Double = 24.0
    var featureGates = PrimordialSoupLifecycleFeatureGates.v01Baseline
    var pendingGenerationSettings = PrimordialSoupLifecycleGenerationSettings.defaults
    var activeBehaviorSpace: PrimordialSoupLifecycleBehaviorSpace = PrimordialSoupLifecycleBehaviorSpaceGenerator.generate(
        settings: PrimordialSoupLifecycleGenerationSettings.defaults
    )
    var savedBehaviorSpaces: [PrimordialSoupLifecycleBehaviorSpace] = []
    var regenerationNonce: UInt64 = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case randomDistribution
        case initialPopulationPercent
        case innerRadiusMultiplier
        case middleRadiusMultiplier
        case outerRadiusMultiplier
        case attractionMultiplier
        case repulsionMultiplier
        case dampingEnabled
        case dampingStrength
        case momentumEnabled
        case momentumStrength
        case speedLimitEnabled
        case speedLimit
        case teleportationEnabled
        case teleportationGeneralInteractionBudget
        case teleportationSelfInteractionBudgetLinked
        case teleportationSelfInteractionBudget
        case teleportationAccumulation
        case teleportationRecoveryRate
        case teleportationMinimumDistanceCentimeters
        case featureGates
        case pendingGenerationSettings
        case activeBehaviorSpace
        case savedBehaviorSpaces
        case regenerationNonce
    }

    init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        randomDistribution = try container.decodeIfPresent(Bool.self, forKey: .randomDistribution) ?? defaults.randomDistribution
        initialPopulationPercent = try container.decodeIfPresent(Double.self, forKey: .initialPopulationPercent) ?? defaults.initialPopulationPercent
        innerRadiusMultiplier = try container.decodeIfPresent(Double.self, forKey: .innerRadiusMultiplier) ?? defaults.innerRadiusMultiplier
        middleRadiusMultiplier = try container.decodeIfPresent(Double.self, forKey: .middleRadiusMultiplier) ?? defaults.middleRadiusMultiplier
        outerRadiusMultiplier = try container.decodeIfPresent(Double.self, forKey: .outerRadiusMultiplier) ?? defaults.outerRadiusMultiplier
        attractionMultiplier = try container.decodeIfPresent(Double.self, forKey: .attractionMultiplier) ?? defaults.attractionMultiplier
        repulsionMultiplier = try container.decodeIfPresent(Double.self, forKey: .repulsionMultiplier) ?? defaults.repulsionMultiplier
        dampingEnabled = try container.decodeIfPresent(Bool.self, forKey: .dampingEnabled) ?? defaults.dampingEnabled
        dampingStrength = try container.decodeIfPresent(Double.self, forKey: .dampingStrength) ?? defaults.dampingStrength
        momentumEnabled = try container.decodeIfPresent(Bool.self, forKey: .momentumEnabled) ?? defaults.momentumEnabled
        momentumStrength = try container.decodeIfPresent(Double.self, forKey: .momentumStrength) ?? defaults.momentumStrength
        speedLimitEnabled = try container.decodeIfPresent(Bool.self, forKey: .speedLimitEnabled) ?? defaults.speedLimitEnabled
        speedLimit = try container.decodeIfPresent(Double.self, forKey: .speedLimit) ?? defaults.speedLimit
        teleportationEnabled = try container.decodeIfPresent(Bool.self, forKey: .teleportationEnabled) ?? defaults.teleportationEnabled
        teleportationGeneralInteractionBudget = try container.decodeIfPresent(Int.self, forKey: .teleportationGeneralInteractionBudget) ?? defaults.teleportationGeneralInteractionBudget
        teleportationSelfInteractionBudgetLinked = try container.decodeIfPresent(Bool.self, forKey: .teleportationSelfInteractionBudgetLinked) ?? defaults.teleportationSelfInteractionBudgetLinked
        teleportationSelfInteractionBudget = try container.decodeIfPresent(Int.self, forKey: .teleportationSelfInteractionBudget) ?? defaults.teleportationSelfInteractionBudget
        teleportationAccumulation = try container.decodeIfPresent(Double.self, forKey: .teleportationAccumulation) ?? defaults.teleportationAccumulation
        teleportationRecoveryRate = try container.decodeIfPresent(Double.self, forKey: .teleportationRecoveryRate) ?? defaults.teleportationRecoveryRate
        teleportationMinimumDistanceCentimeters = try container.decodeIfPresent(Double.self, forKey: .teleportationMinimumDistanceCentimeters) ?? defaults.teleportationMinimumDistanceCentimeters
        featureGates = (try container.decodeIfPresent(PrimordialSoupLifecycleFeatureGates.self, forKey: .featureGates) ?? defaults.featureGates).sanitized()
        pendingGenerationSettings = try container.decodeIfPresent(PrimordialSoupLifecycleGenerationSettings.self, forKey: .pendingGenerationSettings) ?? defaults.pendingGenerationSettings
        activeBehaviorSpace = try container.decodeIfPresent(PrimordialSoupLifecycleBehaviorSpace.self, forKey: .activeBehaviorSpace) ?? defaults.activeBehaviorSpace
        savedBehaviorSpaces = try container.decodeIfPresent([PrimordialSoupLifecycleBehaviorSpace].self, forKey: .savedBehaviorSpaces) ?? defaults.savedBehaviorSpaces
        regenerationNonce = try container.decodeIfPresent(UInt64.self, forKey: .regenerationNonce) ?? defaults.regenerationNonce
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(randomDistribution, forKey: .randomDistribution)
        try container.encode(initialPopulationPercent, forKey: .initialPopulationPercent)
        try container.encode(innerRadiusMultiplier, forKey: .innerRadiusMultiplier)
        try container.encode(middleRadiusMultiplier, forKey: .middleRadiusMultiplier)
        try container.encode(outerRadiusMultiplier, forKey: .outerRadiusMultiplier)
        try container.encode(attractionMultiplier, forKey: .attractionMultiplier)
        try container.encode(repulsionMultiplier, forKey: .repulsionMultiplier)
        try container.encode(dampingEnabled, forKey: .dampingEnabled)
        try container.encode(dampingStrength, forKey: .dampingStrength)
        try container.encode(momentumEnabled, forKey: .momentumEnabled)
        try container.encode(momentumStrength, forKey: .momentumStrength)
        try container.encode(speedLimitEnabled, forKey: .speedLimitEnabled)
        try container.encode(speedLimit, forKey: .speedLimit)
        try container.encode(teleportationEnabled, forKey: .teleportationEnabled)
        try container.encode(teleportationGeneralInteractionBudget, forKey: .teleportationGeneralInteractionBudget)
        try container.encode(teleportationSelfInteractionBudgetLinked, forKey: .teleportationSelfInteractionBudgetLinked)
        try container.encode(teleportationSelfInteractionBudget, forKey: .teleportationSelfInteractionBudget)
        try container.encode(teleportationAccumulation, forKey: .teleportationAccumulation)
        try container.encode(teleportationRecoveryRate, forKey: .teleportationRecoveryRate)
        try container.encode(teleportationMinimumDistanceCentimeters, forKey: .teleportationMinimumDistanceCentimeters)
        try container.encode(featureGates, forKey: .featureGates)
        try container.encode(pendingGenerationSettings, forKey: .pendingGenerationSettings)
        try container.encode(activeBehaviorSpace, forKey: .activeBehaviorSpace)
        try container.encode(savedBehaviorSpaces, forKey: .savedBehaviorSpaces)
        try container.encode(regenerationNonce, forKey: .regenerationNonce)
    }

    var hasPendingBehaviorSpaceChanges: Bool {
        pendingGenerationSettings.sanitized() != activeBehaviorSpace.generationSettings.sanitized()
    }

    func sanitized() -> PrimordialSoupLifecycleSettings {
        var next = self
        next.initialPopulationPercent = min(max(0.01, next.initialPopulationPercent), 1.0)
        next.innerRadiusMultiplier = min(max(Self.radiusMultiplierRange.lowerBound, next.innerRadiusMultiplier), Self.radiusMultiplierRange.upperBound)
        next.middleRadiusMultiplier = min(max(Self.radiusMultiplierRange.lowerBound, next.middleRadiusMultiplier), Self.radiusMultiplierRange.upperBound)
        next.outerRadiusMultiplier = min(max(Self.radiusMultiplierRange.lowerBound, next.outerRadiusMultiplier), Self.radiusMultiplierRange.upperBound)
        next.attractionMultiplier = min(max(0, next.attractionMultiplier), Self.interactionMultiplierUICap)
        next.repulsionMultiplier = min(max(0, next.repulsionMultiplier), Self.interactionMultiplierUICap)
        next.dampingStrength = min(max(0, next.dampingStrength), TypeMatrixLocalPhysicsSettings.dampingStrengthUICap)
        next.momentumStrength = min(max(0, next.momentumStrength), TypeMatrixLocalPhysicsSettings.momentumStrengthUICap)
        next.speedLimit = min(max(0, next.speedLimit), TypeMatrixLocalPhysicsSettings.speedLimitUICap)
        next.teleportationGeneralInteractionBudget = min(max(0, next.teleportationGeneralInteractionBudget), TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetHardCap)
        next.teleportationSelfInteractionBudget = min(max(0, next.teleportationSelfInteractionBudget), TypeMatrixLocalPhysicsSettings.correctiveBehaviorBudgetHardCap)
        next.teleportationAccumulation = min(max(0, next.teleportationAccumulation), TypeMatrixLocalPhysicsSettings.teleportationAccumulationUICap)
        next.teleportationRecoveryRate = min(max(0, next.teleportationRecoveryRate), TypeMatrixLocalPhysicsSettings.teleportationRecoveryUICap)
        next.teleportationMinimumDistanceCentimeters = min(
            max(0, next.teleportationMinimumDistanceCentimeters),
            TypeMatrixLocalPhysicsSettings.teleportationMinimumDistanceUICapCentimeters
        )
        next.featureGates = next.featureGates.sanitized()
        next.pendingGenerationSettings = next.pendingGenerationSettings.sanitized()
        next.activeBehaviorSpace = Self.repairedBehaviorSpace(next.activeBehaviorSpace)
        next.savedBehaviorSpaces = Array(next.savedBehaviorSpaces
            .map(Self.repairedBehaviorSpace)
            .suffix(20))
        return next
    }

    var activeTypeCount: Int {
        activeBehaviorSpace.typeCount
    }

    var teleportationMinimumDistanceWorldUnits: Double {
        TypeMatrixLocalPhysicsSettings.worldUnits(fromCentimeters: teleportationMinimumDistanceCentimeters)
    }

    static func worldUnits(fromCentimeters centimeters: Double) -> Double {
        TypeMatrixLocalPhysicsSettings.worldUnits(fromCentimeters: centimeters)
    }

    static func repairedBehaviorSpace(_ behaviorSpace: PrimordialSoupLifecycleBehaviorSpace) -> PrimordialSoupLifecycleBehaviorSpace {
        var next = behaviorSpace
        next.generationSettings = next.generationSettings.sanitized()
        let typeCount = next.generationSettings.typeCount
        if next.typeProfiles.count != typeCount || next.relationships.count != typeCount * typeCount {
            next = PrimordialSoupLifecycleBehaviorSpaceGenerator.generate(settings: next.generationSettings)
        }
        return next
    }
}

enum PrimordialSoupLifecycleBehaviorSpaceGenerator {
    static func generate(
        settings rawSettings: PrimordialSoupLifecycleGenerationSettings,
        createdAt: Date = Date()
    ) -> PrimordialSoupLifecycleBehaviorSpace {
        let settings = rawSettings.sanitized()
        var rng = SeededGenerator(seed: settings.seed == 0 ? UInt64(Date().timeIntervalSince1970 * 1000) : settings.seed)
        let typeProfiles = (0..<settings.typeCount).map { typeIndex in
            makeTypeProfile(typeIndex: typeIndex, settings: settings, rng: &rng)
        }
        var relationships: [PrimordialSoupLifecycleRelationship] = []
        relationships.reserveCapacity(settings.typeCount * settings.typeCount)
        for source in 0..<settings.typeCount {
            for target in 0..<settings.typeCount {
                relationships.append(makeRelationship(source: source, target: target, settings: settings, rng: &rng))
            }
        }
        return PrimordialSoupLifecycleBehaviorSpace(
            id: UUID().uuidString,
            createdAt: createdAt,
            generationSettings: settings,
            typeProfiles: typeProfiles,
            relationships: relationships
        )
    }

    private static func makeTypeProfile(
        typeIndex: Int,
        settings: PrimordialSoupLifecycleGenerationSettings,
        rng: inout SeededGenerator
    ) -> PrimordialSoupLifecycleTypeProfile {
        let stablePhase = Double(typeIndex) / Double(max(1, settings.typeCount))
        let stableWave = (sin(stablePhase * Double.pi * 2) + 1) * 0.5
        let stableCounterWave = (cos(stablePhase * Double.pi * 2) + 1) * 0.5
        let stability = settings.stability

        func blended(_ random: Double, _ stable: Double) -> Double {
            random * (1 - stability) + stable * stability
        }

        return PrimordialSoupLifecycleTypeProfile(
            maxSpeed: settings.maxSpeedRange.interpolate(blended(random01(&rng), stableWave)),
            motility: settings.motilityRange.interpolate(blended(random01(&rng), 0.25 + stableCounterWave * 0.35)),
            innerRadiusCentimeters: settings.innerRadiusRangeCentimeters.interpolate(blended(random01(&rng), 0.35)),
            middleRadiusCentimeters: settings.middleRadiusRangeCentimeters.interpolate(blended(random01(&rng), 0.45)),
            outerRadiusCentimeters: settings.outerRadiusRangeCentimeters.interpolate(blended(random01(&rng), 0.45 + stableWave * 0.25)),
            energyDecayRate: settings.energyDecayRange.interpolate(blended(random01(&rng), 0.35 + stableWave * 0.25)),
            reproductionEnergyThreshold: settings.reproductionThresholdRange.interpolate(blended(random01(&rng), 0.55 + stableCounterWave * 0.20)),
            reproductionEnergyCost: settings.reproductionCostRange.interpolate(blended(random01(&rng), 0.45 + stableWave * 0.20)),
            childEnergyFraction: settings.childEnergyFractionRange.interpolate(blended(random01(&rng), 0.45)),
            reproductionCooldown: settings.reproductionCooldownRange.interpolate(blended(random01(&rng), 0.45 + stableCounterWave * 0.20)),
            threatSensitivity: settings.threatSensitivityRange.interpolate(blended(random01(&rng), 0.45 + stableWave * 0.20))
        )
    }

    private static func makeRelationship(
        source: Int,
        target: Int,
        settings: PrimordialSoupLifecycleGenerationSettings,
        rng: inout SeededGenerator
    ) -> PrimordialSoupLifecycleRelationship {
        let signedForce = active(probability: settings.forceComplexity, rng: &rng)
            ? stableSignedForce(source: source, target: target, settings: settings, rng: &rng)
            : 0
        let energyCost = active(probability: settings.complexity, rng: &rng)
            ? stableEnergyCost(source: source, target: target, signedForce: signedForce, settings: settings, rng: &rng)
            : 0
        let threatContribution = active(probability: settings.complexity, rng: &rng)
            ? settings.threatContributionRange.interpolate(stableThreatValue(energyCost: energyCost, settings: settings, rng: &rng))
            : 0

        return PrimordialSoupLifecycleRelationship(
            signedForce: signedForce,
            energyCost: energyCost,
            threatContribution: threatContribution
        )
    }

    private static func stableSignedForce(
        source: Int,
        target: Int,
        settings: PrimordialSoupLifecycleGenerationSettings,
        rng: inout SeededGenerator
    ) -> Double {
        if source == target {
            let stableSelf = max(0, -settings.signedForceRange.minimum) > 0 ? settings.signedForceRange.minimum * 0.35 : 0
            return randomSignedForce(settings: settings, rng: &rng) * (1 - settings.stability) + stableSelf * settings.stability
        }

        let typeCount = max(1, settings.typeCount)
        let forward = (target - source + typeCount) % typeCount
        let half = max(1, typeCount / 2)
        let stableMagnitude = 1.0 - min(1.0, abs(Double(forward) - 1.0) / Double(max(1, half)))
        let stableSign = forward <= half ? 1.0 : -1.0
        let stableUnit = stableSign * max(0.15, stableMagnitude)
        let stableValue = stableUnit >= 0
            ? settings.signedForceRange.interpolate(0.5 + stableUnit * 0.5)
            : settings.signedForceRange.interpolate(0.5 + stableUnit * 0.5)
        return randomSignedForce(settings: settings, rng: &rng) * (1 - settings.stability) + stableValue * settings.stability
    }

    private static func randomSignedForce(
        settings: PrimordialSoupLifecycleGenerationSettings,
        rng: inout SeededGenerator
    ) -> Double {
        settings.signedForceRange.interpolate(random01(&rng))
    }

    private static func stableEnergyCost(
        source: Int,
        target: Int,
        signedForce: Double,
        settings: PrimordialSoupLifecycleGenerationSettings,
        rng: inout SeededGenerator
    ) -> Double {
        let random = settings.energyCostRange.interpolate(random01(&rng))
        let typeCount = max(1, settings.typeCount)
        let isNextInCycle = target == (source + 1) % typeCount
        let isPreviousInCycle = source == (target + 1) % typeCount
        let stableT: Double
        if isNextInCycle {
            stableT = 0.18
        } else if isPreviousInCycle {
            stableT = 0.78
        } else if signedForce > 0 {
            stableT = 0.42
        } else {
            stableT = 0.54
        }
        let stable = settings.energyCostRange.interpolate(stableT)
        return random * (1 - settings.stability) + stable * settings.stability
    }

    private static func stableThreatValue(
        energyCost: Double,
        settings: PrimordialSoupLifecycleGenerationSettings,
        rng: inout SeededGenerator
    ) -> Double {
        let random = random01(&rng)
        let stable = energyCost > 0 ? 0.72 : 0.12
        return random * (1 - settings.stability) + stable * settings.stability
    }

    private static func active(probability: Double, rng: inout SeededGenerator) -> Bool {
        random01(&rng) <= min(max(probability, 0), 1)
    }

    private static func random01(_ rng: inout SeededGenerator) -> Double {
        Double(rng.next() >> 11) / Double(1 << 53)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x12345678abcdef : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
}

extension MainWindowPhysicsModuleSettingsStore {
    func primordialSoupLifecycleSettings() -> PrimordialSoupLifecycleSettings {
        primordialSoupLifecycleSettings(from: snapshot)
    }

    func primordialSoupLifecycleSettings(
        from snapshot: MainWindowPhysicsModuleSettingsSnapshot
    ) -> PrimordialSoupLifecycleSettings {
        decodeSettings(
            for: PrimordialSoupLifecycleSettings.moduleName,
            fallback: PrimordialSoupLifecycleSettings(),
            from: snapshot
        ).sanitized()
    }

    func setPrimordialSoupLifecycleSettings(_ nextSettings: PrimordialSoupLifecycleSettings) {
        updateSettings(nextSettings.sanitized(), for: PrimordialSoupLifecycleSettings.moduleName)
    }

    func regeneratePrimordialSoupLifecycleBehaviorSpace() {
        var next = primordialSoupLifecycleSettings()
        var generationSettings = next.pendingGenerationSettings.sanitized()
        generationSettings.seed &+= 1
        next.pendingGenerationSettings = generationSettings
        next.activeBehaviorSpace = PrimordialSoupLifecycleBehaviorSpaceGenerator.generate(settings: generationSettings)
        next.regenerationNonce &+= 1
        setPrimordialSoupLifecycleSettings(next)
    }

    func restorePrimordialSoupLifecycleDefaults() {
        var next = primordialSoupLifecycleSettings()
        next.pendingGenerationSettings = .defaults
        setPrimordialSoupLifecycleSettings(next)
    }

    func restorePrimordialSoupLifecycleFromActiveSpace() {
        var next = primordialSoupLifecycleSettings()
        next.pendingGenerationSettings = next.activeBehaviorSpace.generationSettings
        setPrimordialSoupLifecycleSettings(next)
    }

    func savePrimordialSoupLifecycleWorkingCopy() {
        var next = primordialSoupLifecycleSettings()
        next.savedBehaviorSpaces.append(next.activeBehaviorSpace)
        setPrimordialSoupLifecycleSettings(next)
    }

    func loadLatestPrimordialSoupLifecycleSavedSpace() {
        var next = primordialSoupLifecycleSettings()
        guard let saved = next.savedBehaviorSpaces.last else { return }
        next.activeBehaviorSpace = saved
        next.pendingGenerationSettings = saved.generationSettings
        next.regenerationNonce &+= 1
        setPrimordialSoupLifecycleSettings(next)
    }
}
