import Foundation
import Metal
import simd

struct LineUniforms {
    var mvp: float4x4
    var color: SIMD4<Float>
}

struct ParticleUniforms {
    var mvp: float4x4
    var sphereSize: Float
    var viewportHeight: Float
    var projectionYScale: Float
    var spectrumOffset: Float
    var particleTypeCount: UInt32
    var showOptimizationInfo: UInt32
    var padding: UInt32 = 0
}

struct ProfileHeaderParticleUniforms {
    var mvp: float4x4
    var nodeColor: SIMD4<Float>
    var nodeSizeFloor: Float
    var nodeSizeCeiling: Float
    var viewportHeight: Float
    var projectionYScale: Float
}

struct ProfileHeaderVertVertex {
    var position: SIMD4<Float>

    init(_ position: SIMD3<Float>) {
        self.position = SIMD4<Float>(position.x, position.y, position.z, 1)
    }
}

enum ProfileHeaderVertGeometry {
    static func varianceSample(sourceIndex: Int, targetIndex: Int) -> Float {
        let mixed = (sourceIndex &* 73_856_093) ^ (targetIndex &* 19_349_663)
        return Float(mixed & 0xFFFF) / 65_535
    }
}

struct MLPlaybackSurfaceUniforms {
    var mvp: float4x4
    var spectrumOffset: Float
    var amplitudeScale: Float
    var surfaceCount: UInt32
    var visualRecipe: UInt32
    var padding0: UInt32 = 0
    var frontLayerHorizontalOffset: Float = -0.24
    var middleLayerHorizontalOffset: Float = 0.0
    var finalLayerHorizontalOffset: Float = 0.24
    var frontLayerOffset: Float = 0.32
    var middleLayerOffset: Float = 0.0
    var finalLayerOffset: Float = -0.32
}

struct PlaybackMeshSmoothParams {
    var particleCount: UInt32
    var gridSide: UInt32
    var smoothing: Float
    var padding0: UInt32 = 0
}

struct LineVertex {
    var position: SIMD3<Float>
}

struct CameraTransition {
    let start: ViewportCameraState
    let end: ViewportCameraState
    let startedAt: TimeInterval
    let duration: TimeInterval
}

enum CameraMath {
    static let worldUp = SIMD3<Float>(0, 0, 1)
    static let orbitMinRadius: Float = 0.12
    static let orbitMaxRadius: Float = 2.5
    static let navBounds: ClosedRange<Float> = -2.5...2.5
    static let pitchLimit: Float = 1.35
    static let movementSpeedRange: ClosedRange<Float> = 0.2...4.0

    static func resetState(for mode: ViewportCameraMode) -> ViewportCameraState {
        var state = ViewportCameraState()
        state.mode = mode
        state.movementSpeed = ViewportCameraState.defaultMovementSpeed
        return state
    }

    static func clampPitch(_ pitch: Float) -> Float {
        max(-pitchLimit, min(pitchLimit, pitch))
    }

    static func clampMovementSpeed(_ speed: Float) -> Float {
        max(movementSpeedRange.lowerBound, min(movementSpeedRange.upperBound, speed))
    }

    static func forwardVector(yaw: Float, pitch: Float) -> SIMD3<Float> {
        simd_normalize(
            SIMD3<Float>(
                cosf(pitch) * sinf(yaw),
                cosf(pitch) * cosf(yaw),
                sinf(pitch)
            )
        )
    }

    static func rightVector(yaw: Float, pitch: Float) -> SIMD3<Float> {
        let forward = forwardVector(yaw: yaw, pitch: pitch)
        return simd_normalize(simd_cross(forward, worldUp))
    }

    static func upVector(yaw: Float, pitch: Float) -> SIMD3<Float> {
        let forward = forwardVector(yaw: yaw, pitch: pitch)
        let right = rightVector(yaw: yaw, pitch: pitch)
        return simd_normalize(simd_cross(right, forward))
    }

    static func orbitPosition(yaw: Float, pitch: Float, radius: Float) -> SIMD3<Float> {
        forwardVector(yaw: yaw, pitch: pitch) * radius
    }

    static func orbitComponents(position: SIMD3<Float>) -> (yaw: Float, pitch: Float, radius: Float) {
        let radius = max(orbitMinRadius, simd_length(position))
        let normalized = position / radius
        return (
            yaw: atan2f(normalized.x, normalized.y),
            pitch: asinf(max(-1, min(1, normalized.z))),
            radius: radius
        )
    }

    static func legalOrbitOrientation(for position: SIMD3<Float>) -> (yaw: Float, pitch: Float) {
        let directionToCenter = simd_length_squared(position) > 0.000_001
            ? simd_normalize(-position)
            : forwardVector(yaw: ViewportCameraState.defaultYaw, pitch: ViewportCameraState.defaultPitch)
        return (
            yaw: atan2f(directionToCenter.x, directionToCenter.y),
            pitch: clampPitch(asinf(max(-1, min(1, directionToCenter.z))))
        )
    }

    static func clampNavigationPosition(_ position: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            max(navBounds.lowerBound, min(navBounds.upperBound, position.x)),
            max(navBounds.lowerBound, min(navBounds.upperBound, position.y)),
            max(navBounds.lowerBound, min(navBounds.upperBound, position.z))
        )
    }

    static func correctedOrbitState(from state: ViewportCameraState) -> ViewportCameraState {
        var corrected = state
        corrected.mode = .orbit
        let radius = simd_length(state.position)
        if radius > orbitMaxRadius {
            let direction = simd_length_squared(state.position) > 0.000_001
                ? simd_normalize(state.position)
                : simd_normalize(ViewportCameraState.defaultPosition)
            corrected.position = direction * (orbitMaxRadius - 0.01)
        }
        let orientation = legalOrbitOrientation(for: corrected.position)
        corrected.yaw = orientation.yaw
        corrected.pitch = orientation.pitch
        corrected.movementSpeed = clampMovementSpeed(corrected.movementSpeed)
        return corrected
    }

    static func viewMatrix(for state: ViewportCameraState) -> float4x4 {
        .lookAt(
            eye: float3(state.position),
            center: float3(state.position + forwardVector(yaw: state.yaw, pitch: state.pitch)),
            up: float3(upVector(yaw: state.yaw, pitch: state.pitch))
        )
    }
}

final class CameraState {
    private(set) var authoritativeState: ViewportCameraState
    private(set) var renderedState: ViewportCameraState
    private(set) var transition: CameraTransition?

    init(viewportCameraState: ViewportCameraState = ViewportCameraState()) {
        self.authoritativeState = viewportCameraState
        self.renderedState = viewportCameraState
    }

    var isTransitioning: Bool {
        transition != nil
    }

    func syncControls(from desiredState: ViewportCameraState, now: TimeInterval) {
        authoritativeState.movementSpeed = CameraMath.clampMovementSpeed(desiredState.movementSpeed)
        if desiredState.mode != authoritativeState.mode {
            switch desiredState.mode {
            case .navigation:
                authoritativeState.mode = .navigation
                renderedState.mode = .navigation
                transition = nil
            case .orbit:
                let correctedTarget = CameraMath.correctedOrbitState(from: authoritativeState)
                authoritativeState = correctedTarget
                transition = CameraTransition(
                    start: renderedState,
                    end: correctedTarget,
                    startedAt: now,
                    duration: 0.5
                )
            }
        }
    }

    func updateTransition(now: TimeInterval) {
        guard let transition else { return }
        // TODO: First pass uses a simple 0.5 second lerp. Upgrade the transition model later if the motion needs more polish.
        let progress = min(max(Float((now - transition.startedAt) / transition.duration), 0), 1)
        renderedState = interpolate(from: transition.start, to: transition.end, progress: progress)
        if progress >= 1 {
            renderedState = transition.end
            self.transition = nil
        }
    }

    func rotateInPlace(yawDelta: Float, pitchDelta: Float) {
        guard !isTransitioning else { return }
        authoritativeState.yaw += yawDelta
        authoritativeState.pitch = CameraMath.clampPitch(authoritativeState.pitch + pitchDelta)
        renderedState = authoritativeState
    }

    func updateNavigationTranslation(forward: Float, right: Float, up: Float, deltaTime: Float) {
        guard !isTransitioning else { return }
        let moveScale = authoritativeState.movementSpeed * deltaTime
        let offset =
            CameraMath.forwardVector(yaw: authoritativeState.yaw, pitch: authoritativeState.pitch) * forward
            + CameraMath.rightVector(yaw: authoritativeState.yaw, pitch: authoritativeState.pitch) * right
            + CameraMath.upVector(yaw: authoritativeState.yaw, pitch: authoritativeState.pitch) * up
        authoritativeState.position = CameraMath.clampNavigationPosition(authoritativeState.position + offset * moveScale)
        renderedState = authoritativeState
    }

    func updateOrbitMotion(yawDelta: Float, pitchDelta: Float, radiusDelta: Float) {
        guard !isTransitioning else { return }
        var orbit = CameraMath.orbitComponents(position: authoritativeState.position)
        orbit.yaw += yawDelta
        orbit.pitch = CameraMath.clampPitch(orbit.pitch + pitchDelta)
        orbit.radius = max(CameraMath.orbitMinRadius, min(CameraMath.orbitMaxRadius, orbit.radius + radiusDelta))
        authoritativeState.position = CameraMath.orbitPosition(yaw: orbit.yaw, pitch: orbit.pitch, radius: orbit.radius)
        let orientation = CameraMath.legalOrbitOrientation(for: authoritativeState.position)
        authoritativeState.yaw = orientation.yaw
        authoritativeState.pitch = orientation.pitch
        renderedState = authoritativeState
    }

    func adjustMovementSpeed(byScrollDelta deltaY: Float) {
        guard !isTransitioning else { return }
        let nextSpeed = authoritativeState.movementSpeed * expf(-deltaY * 0.035)
        authoritativeState.movementSpeed = CameraMath.clampMovementSpeed(nextSpeed)
        renderedState.movementSpeed = authoritativeState.movementSpeed
    }

    func reset() {
        guard !isTransitioning else { return }
        authoritativeState = CameraMath.resetState(for: authoritativeState.mode)
        renderedState = authoritativeState
    }

    func viewMatrix() -> float4x4 {
        CameraMath.viewMatrix(for: renderedState)
    }

    private func interpolate(from start: ViewportCameraState, to end: ViewportCameraState, progress: Float) -> ViewportCameraState {
        var state = end
        state.position = simd_mix(start.position, end.position, SIMD3<Float>(repeating: progress))
        state.yaw = start.yaw + (end.yaw - start.yaw) * progress
        state.pitch = start.pitch + (end.pitch - start.pitch) * progress
        state.movementSpeed = end.movementSpeed
        state.mode = end.mode
        return state
    }
}

struct TSPWireframeGeometry {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    static func make(device: MTLDevice) throws -> TSPWireframeGeometry {
        let lineVertices: [LineVertex] = [
            LineVertex(position: [-1, -1, -1]),
            LineVertex(position: [ 1, -1, -1]),
            LineVertex(position: [ 1,  1, -1]),
            LineVertex(position: [-1,  1, -1]),
            LineVertex(position: [-1, -1,  1]),
            LineVertex(position: [ 1, -1,  1]),
            LineVertex(position: [ 1,  1,  1]),
            LineVertex(position: [-1,  1,  1]),
        ]

        let lineIndices: [UInt16] = [
            0,1, 1,2, 2,3, 3,0,
            4,5, 5,6, 6,7, 7,4,
            0,4, 1,5, 2,6, 3,7,
        ]

        guard
            let vertexBuffer = device.makeBuffer(
                bytes: lineVertices,
                length: MemoryLayout<LineVertex>.stride * lineVertices.count
            ),
            let indexBuffer = device.makeBuffer(
                bytes: lineIndices,
                length: MemoryLayout<UInt16>.stride * lineIndices.count
            )
        else {
            throw RendererError.vertexBufferCreationFailed("tsp-wireframe")
        }

        return TSPWireframeGeometry(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: lineIndices.count
        )
    }
}

struct RendererFrameRateTracker {
    private let windowSeconds: TimeInterval
    private var timestamps: [TimeInterval] = []

    init(windowSeconds: TimeInterval) {
        self.windowSeconds = windowSeconds
    }

    mutating func recordFrame(at now: TimeInterval) {
        timestamps.append(now)
        let cutoff = now - windowSeconds
        timestamps.removeAll { $0 < cutoff }
    }

    func averageFPS() -> Double {
        guard let first = timestamps.first, let last = timestamps.last, last > first else {
            return timestamps.isEmpty ? 0 : Double(timestamps.count) / windowSeconds
        }
        return Double(timestamps.count) / max(last - first, 0.001)
    }
}

struct DebugLineFadeController {
    let fadeInDuration: TimeInterval
    let fadeOutDuration: TimeInterval

    func alpha(at now: TimeInterval, startedAt: TimeInterval) -> Double {
        let fadeIn = fadeInAlpha(at: now, startedAt: startedAt)
        let fadeOut = fadeOutAlpha(at: now, fadeStartedAt: startedAt + fadeInDuration)
        return min(fadeIn, fadeOut)
    }

    private func fadeInAlpha(at now: TimeInterval, startedAt: TimeInterval) -> Double {
        guard startedAt > 0 else { return 1 }
        let progress = min(max((now - startedAt) / fadeInDuration, 0), 1)
        return progress
    }

    private func fadeOutAlpha(at now: TimeInterval, fadeStartedAt: TimeInterval) -> Double {
        guard fadeStartedAt > 0 else { return 0 }
        let progress = min(max((now - fadeStartedAt) / fadeOutDuration, 0), 1)
        return 1 - progress
    }
}
