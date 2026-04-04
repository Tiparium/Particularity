import Foundation

struct TypeMatrixLocalPhysicsSettings: Codable, Equatable, Sendable {
    static let moduleName = "TypeMatrixLocalAttractionRepulsion"
    static let maxParticleTypes = 32
    static let simulationCubeSideMeters = 1.0
    static let simulationCubeSideWorldUnits = 2.0
    static let centimetersPerMeter = 100.0
    static let zoneUICapCentimeters = 12.0
    static let matrixValueUICapMagnitude = 16
    static let interactionMultiplierUICap = 4.0
    static let dampingStrengthDefault = 0.92
    static let momentumStrengthDefault = 0.18
    static let speedLimitDefault = 2.4
    static let dampingStrengthUICap = 1.0
    static let momentumStrengthUICap = 1.0
    static let speedLimitUICap = 12.0

    var innerRadiusCentimeters: Double = 2.5
    var middleRadiusCentimeters: Double = 1.5
    var outerRadiusCentimeters: Double = 2.5
    var randomizeOnSimulationStart = true
    var matrixMinimumValue: Int = -1
    var matrixMaximumValue: Int = 1
    var attractionMultiplier: Double = 1.0
    var repulsionMultiplier: Double = 1.0
    var dampingEnabled = true
    var dampingStrength: Double = dampingStrengthDefault
    var momentumEnabled = true
    var momentumStrength: Double = momentumStrengthDefault
    var speedLimitEnabled = true
    var speedLimit: Double = speedLimitDefault
    var matrixValues: [Int] = TypeMatrixLocalPhysicsSettings.makeRandomMatrix()
    var regenerationNonce: UInt64 = 0

    var innerRadiusWorldUnits: Double {
        Self.worldUnits(fromCentimeters: innerRadiusCentimeters)
    }

    var middleRadiusWorldUnits: Double {
        Self.worldUnits(fromCentimeters: middleRadiusCentimeters)
    }

    var outerRadiusWorldUnits: Double {
        Self.worldUnits(fromCentimeters: outerRadiusCentimeters)
    }

    static func worldUnits(fromCentimeters centimeters: Double) -> Double {
        let meters = centimeters / centimetersPerMeter
        return meters * simulationCubeSideWorldUnits / simulationCubeSideMeters
    }

    static func makeRandomMatrix(
        sideLength: Int = maxParticleTypes,
        minimumValue: Int = -1,
        maximumValue: Int = 1
    ) -> [Int] {
        let safeSideLength = max(1, sideLength)
        let clampedMinimum = max(-matrixValueUICapMagnitude, min(matrixValueUICapMagnitude, minimumValue))
        let clampedMaximum = max(clampedMinimum, min(matrixValueUICapMagnitude, maximumValue))
        var generator = SystemRandomNumberGenerator()
        var matrix: [Int] = []
        matrix.reserveCapacity(safeSideLength * safeSideLength)

        for _ in 0..<(safeSideLength * safeSideLength) {
            matrix.append(Int.random(in: clampedMinimum...clampedMaximum, using: &generator))
        }

        return matrix
    }

    mutating func resetDampingToDefault() {
        dampingEnabled = true
        dampingStrength = Self.dampingStrengthDefault
    }

    mutating func resetMomentumToDefault() {
        momentumEnabled = true
        momentumStrength = Self.momentumStrengthDefault
    }

    mutating func resetSpeedLimitToDefault() {
        speedLimitEnabled = true
        speedLimit = Self.speedLimitDefault
    }

    func sanitized() -> TypeMatrixLocalPhysicsSettings {
        var next = self
        next.innerRadiusCentimeters = min(max(0, next.innerRadiusCentimeters), Self.zoneUICapCentimeters)
        next.middleRadiusCentimeters = min(max(0, next.middleRadiusCentimeters), Self.zoneUICapCentimeters)
        next.outerRadiusCentimeters = min(max(0, next.outerRadiusCentimeters), Self.zoneUICapCentimeters)
        next.matrixMinimumValue = min(
            max(-Self.matrixValueUICapMagnitude, next.matrixMinimumValue),
            Self.matrixValueUICapMagnitude
        )
        next.matrixMaximumValue = min(
            max(-Self.matrixValueUICapMagnitude, next.matrixMaximumValue),
            Self.matrixValueUICapMagnitude
        )
        if next.matrixMinimumValue > next.matrixMaximumValue {
            next.matrixMinimumValue = next.matrixMaximumValue
        }
        next.attractionMultiplier = min(max(0, next.attractionMultiplier), Self.interactionMultiplierUICap)
        next.repulsionMultiplier = min(max(0, next.repulsionMultiplier), Self.interactionMultiplierUICap)
        next.dampingStrength = min(max(0, next.dampingStrength), Self.dampingStrengthUICap)
        next.momentumStrength = min(max(0, next.momentumStrength), Self.momentumStrengthUICap)
        next.speedLimit = min(max(0, next.speedLimit), Self.speedLimitUICap)
        let requiredCount = Self.maxParticleTypes * Self.maxParticleTypes
        if next.matrixValues.count != requiredCount {
            var repaired = Array(next.matrixValues.prefix(requiredCount))
            if repaired.count < requiredCount {
                repaired.append(contentsOf: Array(repeating: 0, count: requiredCount - repaired.count))
            }
            next.matrixValues = repaired.map {
                min(next.matrixMaximumValue, max(next.matrixMinimumValue, $0))
            }
        } else {
            next.matrixValues = next.matrixValues.map {
                min(next.matrixMaximumValue, max(next.matrixMinimumValue, $0))
            }
        }
        return next
    }
}

extension MainWindowPhysicsModuleSettingsStore {
    func typeMatrixLocalSettings() -> TypeMatrixLocalPhysicsSettings {
        decodeSettings(
            for: TypeMatrixLocalPhysicsSettings.moduleName,
            fallback: TypeMatrixLocalPhysicsSettings()
        ).sanitized()
    }

    func setTypeMatrixLocalSettings(_ nextSettings: TypeMatrixLocalPhysicsSettings) {
        updateSettings(nextSettings.sanitized(), for: TypeMatrixLocalPhysicsSettings.moduleName)
    }

    func regenerateTypeMatrix() {
        var next = typeMatrixLocalSettings()
        next.matrixValues = TypeMatrixLocalPhysicsSettings.makeRandomMatrix(
            minimumValue: next.matrixMinimumValue,
            maximumValue: next.matrixMaximumValue
        )
        next.regenerationNonce &+= 1
        setTypeMatrixLocalSettings(next)
    }

    func setTypeMatrixValue(row: Int, column: Int, value: Int) {
        guard row >= 0,
              row < TypeMatrixLocalPhysicsSettings.maxParticleTypes,
              column >= 0,
              column < TypeMatrixLocalPhysicsSettings.maxParticleTypes else {
            return
        }

        var next = typeMatrixLocalSettings()
        let index = row * TypeMatrixLocalPhysicsSettings.maxParticleTypes + column
        next.matrixValues[index] = min(next.matrixMaximumValue, max(next.matrixMinimumValue, value))
        setTypeMatrixLocalSettings(next)
    }
}
