import AppKit
import MetalKit
import SwiftUI
import simd

private final class InputMTKView: MTKView {
    weak var inputDelegate: InputMTKViewDelegate?
    private var lastMousePoint: NSPoint = .zero
    private var isDraggingOrbit = false
    private var clickThenDragOrbitActive = false
    private var orbitDisarmWorkItem: DispatchWorkItem?
    private var trackingAreaRef: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        lastMousePoint = p

        switch ProgramSettingsStore.orbitInputMode {
        case .clickAndDrag:
            isDraggingOrbit = true
        case .clickThenDrag:
            clickThenDragOrbitActive = true
            armOrbitDisarmTimer()
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch ProgramSettingsStore.orbitInputMode {
        case .clickAndDrag:
            isDraggingOrbit = false
        case .clickThenDrag:
            // Keep orbit active after click release; disable when touchpad motion ends.
            armOrbitDisarmTimer()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard shouldHandleOrbitMotion else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Float(p.x - lastMousePoint.x)
        let dy = Float(p.y - lastMousePoint.y)
        lastMousePoint = p
        inputDelegate?.didDrag(deltaX: dx, deltaY: dy)
        armOrbitDisarmTimer()
    }

    override func mouseMoved(with event: NSEvent) {
        guard ProgramSettingsStore.orbitInputMode == .clickThenDrag, clickThenDragOrbitActive else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Float(p.x - lastMousePoint.x)
        let dy = Float(p.y - lastMousePoint.y)
        lastMousePoint = p
        inputDelegate?.didDrag(deltaX: dx, deltaY: dy)
        armOrbitDisarmTimer()
    }

    override func mouseExited(with event: NSEvent) {
        disarmOrbit()
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaY = Float(event.scrollingDeltaY)
        inputDelegate?.didScroll(deltaY: deltaY)
    }

    override func magnify(with event: NSEvent) {
        inputDelegate?.didMagnify(Float(event.magnification))
    }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else { return }
        if chars.lowercased() == "f" {
            inputDelegate?.didPressReset()
            return
        }
        inputDelegate?.didPressKey(chars)
    }

    override func keyUp(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else { return }
        inputDelegate?.didReleaseKey(chars)
    }

    private var shouldHandleOrbitMotion: Bool {
        switch ProgramSettingsStore.orbitInputMode {
        case .clickAndDrag:
            return isDraggingOrbit
        case .clickThenDrag:
            return clickThenDragOrbitActive
        }
    }

    private func armOrbitDisarmTimer() {
        guard ProgramSettingsStore.orbitInputMode == .clickThenDrag else { return }
        orbitDisarmWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.clickThenDragOrbitActive = false
        }
        orbitDisarmWorkItem = work
        // No direct "finger lifted" callback exists here; inactivity is the practical stop signal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func disarmOrbit() {
        isDraggingOrbit = false
        clickThenDragOrbitActive = false
        orbitDisarmWorkItem?.cancel()
        orbitDisarmWorkItem = nil
    }
}

@MainActor
protocol InputMTKViewDelegate: AnyObject {
    func didPressKey(_ key: String)
    func didReleaseKey(_ key: String)
    func didDrag(deltaX: Float, deltaY: Float)
    func didScroll(deltaY: Float)
    func didMagnify(_ magnification: Float)
    func didPressReset()
}

@MainActor
final class MetalViewportCoordinator: NSObject, InputMTKViewDelegate {
    var renderer: Renderer?
    fileprivate weak var axisHostView: NSHostingView<ViewportAxisIndicator>?

    func didPressKey(_ key: String) {
        renderer?.registerKeyDown(key)
    }

    func didReleaseKey(_ key: String) {
        renderer?.registerKeyUp(key)
    }

    func didDrag(deltaX: Float, deltaY: Float) {
        renderer?.orbitByDrag(deltaX: deltaX, deltaY: deltaY)
    }

    func didScroll(deltaY: Float) {
        let direction: Float = ProgramSettingsStore.invertScrollZoom ? -1.0 : 1.0
        renderer?.dollyByScroll(deltaY: deltaY * direction)
    }

    func didMagnify(_ magnification: Float) {
        renderer?.dollyByMagnification(magnification)
    }

    func didPressReset() {
        renderer?.resetCamera()
    }

    func updateSimulationState(_ state: SimulationViewportState) {
        renderer?.updateSimulationState(state)
    }
}

struct MetalViewportView: NSViewRepresentable {
    let simulationState: SimulationViewportState
    let onMetricsUpdate: @MainActor (SimulationPerformanceMetrics) -> Void

    func makeCoordinator() -> MetalViewportCoordinator {
        MetalViewportCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        guard let device = MTLCreateSystemDefaultDevice() else {
            return container
        }

        let metalView = InputMTKView(frame: .zero, device: device)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = 60

        let axisHostView = NSHostingView(rootView: ViewportAxisIndicator(cameraState: ViewportCameraState()))
        axisHostView.translatesAutoresizingMaskIntoConstraints = false
        axisHostView.setFrameSize(NSSize(width: 72, height: 72))
        axisHostView.wantsLayer = true
        axisHostView.layer?.backgroundColor = NSColor.clear.cgColor

        guard let renderer = Renderer(
            mtkView: metalView,
            metricsSink: onMetricsUpdate,
            cameraStateSink: { [weak coordinator = context.coordinator] cameraState in
                coordinator?.axisHostView?.rootView = ViewportAxisIndicator(cameraState: cameraState)
            }
        ) else {
            return container
        }
        context.coordinator.renderer = renderer
        context.coordinator.axisHostView = axisHostView
        context.coordinator.updateSimulationState(simulationState)
        metalView.delegate = renderer
        metalView.inputDelegate = context.coordinator

        container.addSubview(metalView)
        container.addSubview(axisHostView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: container.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            axisHostView.widthAnchor.constraint(equalToConstant: 72),
            axisHostView.heightAnchor.constraint(equalToConstant: 72),
            axisHostView.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            axisHostView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateSimulationState(simulationState)
    }
}

private struct ViewportAxisIndicator: View {
    let cameraState: ViewportCameraState

    private struct AxisProjection {
        let label: String
        let color: Color
        let endpoint: CGPoint
        let depth: Float
    }

    var body: some View {
        let axes = projectedAxes

        ZStack {
            ForEach(axes.indices, id: \.self) { index in
                let axis = axes[index]
                Path { path in
                    path.move(to: CGPoint(x: 36, y: 36))
                    path.addLine(to: axis.endpoint)
                }
                .stroke(axis.color.opacity(0.95), lineWidth: 2.4)

                Text(axis.label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(axis.color)
                    .position(axis.endpoint)
            }
        }
        .frame(width: 72, height: 72)
        .background(Color.clear)
    }

    private var projectedAxes: [AxisProjection] {
        let eye = SIMD3<Float>(
            cosf(cameraState.pitch) * sinf(cameraState.yaw),
            sinf(cameraState.pitch),
            cosf(cameraState.pitch) * cosf(cameraState.yaw)
        )
        let zAxis = simd_normalize(eye)
        let xAxis = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        let center = CGPoint(x: 36, y: 36)
        let scale: Float = 22

        let worldAxes: [(String, Color, SIMD3<Float>)] = [
            ("X", .red, SIMD3<Float>(1, 0, 0)),
            ("Y", .green, SIMD3<Float>(0, 1, 0)),
            ("Z", .blue, SIMD3<Float>(0, 0, 1)),
        ]

        return worldAxes
            .map { label, color, axis in
                let cameraSpace = SIMD3<Float>(
                    simd_dot(xAxis, axis),
                    simd_dot(yAxis, axis),
                    simd_dot(zAxis, axis)
                )
                let endpoint = CGPoint(
                    x: center.x + CGFloat(cameraSpace.x * scale),
                    y: center.y - CGFloat(cameraSpace.y * scale)
                )
                return AxisProjection(label: label, color: color, endpoint: endpoint, depth: cameraSpace.z)
            }
            .sorted { $0.depth < $1.depth }
    }
}
