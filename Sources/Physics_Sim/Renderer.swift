import Metal
import MetalKit
import QuartzCore
import simd

private struct Uniforms {
    var mvp: float4x4
    var color: SIMD4<Float>
}

private struct Vertex {
    var position: SIMD3<Float>
}

private final class CameraState {
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
        // Exponential scale gives smoother zoom across large ranges.
        let next = radius * expf(delta)
        radius = max(minRadius, min(maxRadius, next))
    }

    func viewMatrix() -> float4x4 {
        let cx = cosf(pitch) * sinf(yaw)
        let cy = sinf(pitch)
        let cz = cosf(pitch) * cosf(yaw)
        let eye = float3(cx, cy, cz) * radius
        return .lookAt(eye: eye, center: float3(0, 0, 0), up: float3(0, 1, 0))
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let camera = CameraState()

    private var vertexBuffer: MTLBuffer
    private var indexBuffer: MTLBuffer
    private var indexCount: Int
    private var lastTime: CFTimeInterval = CACurrentMediaTime()

    private var activeKeys: Set<String> = []
    private let keyboardAngularSpeed: Float = 1.2

    init?(mtkView: MTKView) {
        guard
            let device = mtkView.device,
            let queue = device.makeCommandQueue()
        else {
            return nil
        }
        self.device = device
        self.queue = queue

        let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float3 position [[attribute(0)]];
        };

        struct Uniforms {
            float4x4 mvp;
            float4 color;
        };

        struct VertexOut {
            float4 position [[position]];
            float4 color;
        };

        vertex VertexOut vs_main(VertexIn in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
            VertexOut out;
            out.position = u.mvp * float4(in.position, 1.0);
            out.color = u.color;
            return out;
        }

        fragment float4 fs_main(VertexOut in [[stage_in]]) {
            return in.color;
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shader, options: nil)
        } catch {
            return nil
        }

        guard
            let vtx = library.makeFunction(name: "vs_main"),
            let frag = library.makeFunction(name: "fs_main")
        else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vtx
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
        desc.vertexDescriptor = vertexDescriptor

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }

        let vertices: [Vertex] = [
            Vertex(position: [-1, -1, -1]),
            Vertex(position: [ 1, -1, -1]),
            Vertex(position: [ 1,  1, -1]),
            Vertex(position: [-1,  1, -1]),
            Vertex(position: [-1, -1,  1]),
            Vertex(position: [ 1, -1,  1]),
            Vertex(position: [ 1,  1,  1]),
            Vertex(position: [-1,  1,  1]),
        ]

        let indices: [UInt16] = [
            0,1, 1,2, 2,3, 3,0,
            4,5, 5,6, 6,7, 7,4,
            0,4, 1,5, 2,6, 3,7,
        ]

        guard
            let vb = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count),
            let ib = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt16>.stride * indices.count)
        else {
            return nil
        }
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = indices.count
    }

    func registerKeyDown(_ key: String) {
        activeKeys.insert(key.lowercased())
    }

    func registerKeyUp(_ key: String) {
        activeKeys.remove(key.lowercased())
    }

    func orbitByDrag(deltaX: Float, deltaY: Float) {
        camera.orbit(yawDelta: deltaX * 0.01, pitchDelta: deltaY * 0.01)
    }

    func dollyByScroll(deltaY: Float) {
        camera.dolly(delta: deltaY * 0.0035)
    }

    func dollyByMagnification(_ magnification: Float) {
        camera.dolly(delta: -magnification * 0.6)
    }

    func resetCamera() {
        camera.reset()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = max(0, min(now - lastTime, 1.0 / 15.0))
        lastTime = now
        updateKeyboardOrbit(deltaTime: Float(dt))

        guard
            let drawable = view.currentDrawable,
            let passDesc = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc)
        else {
            return
        }

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let projection = float4x4.perspective(fovY: 60.0 * .pi / 180.0, aspect: aspect, near: 0.1, far: 100.0)
        let model = float4x4.identity()
        let mvp = projection * camera.viewMatrix() * model

        var uniforms = Uniforms(mvp: mvp, color: SIMD4<Float>(0.78, 0.78, 0.80, 1.0))

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(
            type: .line,
            indexCount: indexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateKeyboardOrbit(deltaTime: Float) {
        var yawDelta: Float = 0
        var pitchDelta: Float = 0
        if activeKeys.contains("a") { yawDelta -= keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("d") { yawDelta += keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("w") { pitchDelta += keyboardAngularSpeed * deltaTime }
        if activeKeys.contains("s") { pitchDelta -= keyboardAngularSpeed * deltaTime }
        if yawDelta != 0 || pitchDelta != 0 {
            camera.orbit(yawDelta: yawDelta, pitchDelta: pitchDelta)
        }
    }
}
