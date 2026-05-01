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
    var playbackRecipe: UInt32
    var isPlaybackVisual: UInt32
    var playbackFrontLayerVisible: UInt32
    var playbackMiddleLayerVisible: UInt32
    var playbackFinalLayerVisible: UInt32
    var playbackFrontLayerSlot: UInt32
    var playbackMiddleLayerSlot: UInt32
    var playbackFinalLayerSlot: UInt32
    var playbackFrontLayerHorizontalOffset: Float
    var playbackMiddleLayerHorizontalOffset: Float
    var playbackFinalLayerHorizontalOffset: Float
    var playbackFrontLayerOffset: Float
    var playbackMiddleLayerOffset: Float
    var playbackFinalLayerOffset: Float
    var playbackForceLayer: UInt32
    var playbackForceSlot: UInt32
    var playbackNormalizationMode: UInt32
    var playbackUsePreparedHeight: UInt32
    var playbackActivationMinimum: Float
    var playbackActivationMaximum: Float
    var padding0: UInt32 = 0
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

final class CameraState {
    var yaw: Float = 0.75
    var pitch: Float = 0.45
    var radius: Float = 3.6
    let minRadius: Float = 0.12
    let maxRadius: Float = 20.0
    let pitchLimit: Float = 1.35

    func reset() {
        yaw = 0.75
        pitch = 0.45
        radius = 3.6
    }

    func orbit(yawDelta: Float, pitchDelta: Float) {
        yaw += yawDelta
        pitch = max(-pitchLimit, min(pitchLimit, pitch + pitchDelta))
    }

    func dolly(delta: Float) {
        let next = radius * expf(delta)
        radius = max(minRadius, min(maxRadius, next))
    }

    func viewMatrix() -> float4x4 {
        // Z-up camera basis:
        // - yaw rotates around +Z
        // - pitch elevates above the XY plane
        let cx = cosf(pitch) * cosf(yaw)
        let cy = cosf(pitch) * sinf(yaw)
        let cz = sinf(pitch)
        let eye = float3(cx, cy, cz) * radius
        return .lookAt(eye: eye, center: float3(0, 0, 0), up: float3(0, 0, 1))
    }

    var viewportCameraState: ViewportCameraState {
        get {
            ViewportCameraState(yaw: yaw, pitch: pitch, radius: radius)
        }
        set {
            yaw = newValue.yaw
            pitch = newValue.pitch
            radius = max(minRadius, min(maxRadius, newValue.radius))
        }
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
