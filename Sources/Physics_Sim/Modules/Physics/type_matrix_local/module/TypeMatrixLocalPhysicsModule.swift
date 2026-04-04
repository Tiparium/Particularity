import Foundation

enum TypeMatrixLocalPhysicsModuleRuntime {
    static func generateInteractionMatrix(
        sideLength: Int = TypeMatrixLocalPhysicsSettings.maxParticleTypes,
        minimumValue: Int = -1,
        maximumValue: Int = 1
    ) -> [Int32] {
        let safeSideLength = max(1, sideLength)
        var generator = SystemRandomNumberGenerator()
        var matrix: [Int32] = []
        matrix.reserveCapacity(safeSideLength * safeSideLength)

        for _ in 0..<(safeSideLength * safeSideLength) {
            matrix.append(Int32(Int.random(in: minimumValue...maximumValue, using: &generator)))
        }

        return matrix
    }
}
