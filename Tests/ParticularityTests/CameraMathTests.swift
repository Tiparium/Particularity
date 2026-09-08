import Foundation
import simd
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

    @Test("navigation camera can move beyond the simulation bounds")
    func navigationCameraHasNoOuterBounds() {
        let camera = CameraState()

        camera.updateNavigationTranslation(forward: 100, right: 0, up: 0, deltaTime: 1)

        #expect(simd_length(camera.authoritativeState.position) > 2.5)
    }

    @Test("orbit camera can move beyond the simulation bounds")
    func orbitCameraHasNoMaximumRadius() {
        var state = ViewportCameraState()
        state.mode = .orbit
        let camera = CameraState(viewportCameraState: state)

        camera.updateOrbitMotion(yawDelta: 0, pitchDelta: 0, radiusDelta: 10)

        #expect(simd_length(camera.authoritativeState.position) > 10)
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
