import Foundation
import Testing
@testable import Particularity

@Suite("Camera math")
struct CameraMathTests {
    @Test("uses Z-up world basis")
    func usesZUpWorldBasis() {
        expectVector(CameraMath.worldUp, equals: SIMD3<Float>(0, 0, 1))
        expectVector(CameraMath.forwardVector(yaw: 0, pitch: 0), equals: SIMD3<Float>(0, 1, 0))
        expectVector(CameraMath.rightVector(yaw: 0, pitch: 0), equals: SIMD3<Float>(1, 0, 0))
        expectVector(CameraMath.upVector(yaw: 0, pitch: 0), equals: SIMD3<Float>(0, 0, 1))
    }

    @Test("default camera position follows Z-up yaw and pitch")
    func defaultCameraPositionFollowsZUpYawAndPitch() {
        let expected = SIMD3<Float>(
            cosf(ViewportCameraState.defaultPitch) * sinf(ViewportCameraState.defaultYaw) * ViewportCameraState.defaultRadius,
            cosf(ViewportCameraState.defaultPitch) * cosf(ViewportCameraState.defaultYaw) * ViewportCameraState.defaultRadius,
            sinf(ViewportCameraState.defaultPitch) * ViewportCameraState.defaultRadius
        )
        expectVector(ViewportCameraState.defaultPosition, equals: expected)
    }

    private func expectVector(
        _ actual: SIMD3<Float>,
        equals expected: SIMD3<Float>,
        tolerance: Float = 0.0001
    ) {
        #expect(abs(actual.x - expected.x) < tolerance)
        #expect(abs(actual.y - expected.y) < tolerance)
        #expect(abs(actual.z - expected.z) < tolerance)
    }
}
