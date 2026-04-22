import AppKit
import MetalKit
import SwiftUI
import simd

private final class InputMTKView: MTKView {
    weak var inputDelegate: InputMTKViewDelegate?
    private var lastMousePoint: NSPoint = .zero
    private var orbitInteractionState = DragInteractionState(clickThenDragEndBehavior: .explicitOrIndirectTouchLift)
    private var trackingAreaRef: NSTrackingArea?
    private let minimumOrbitMotion: Float = 0.35

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            isPaused = false
            enableSetNeedsDisplay = false
            window.makeFirstResponder(self)
            window.acceptsMouseMovedEvents = true
            allowedTouchTypes = [.indirect]
        } else {
            isPaused = true
            disarmOrbit()
        }
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
            _ = orbitInteractionState.beginInteraction(for: ProgramSettingsStore.DragInputMode.clickAndDrag)
        case .clickThenDrag:
            _ = orbitInteractionState.beginInteraction(for: ProgramSettingsStore.DragInputMode.clickThenDrag)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch ProgramSettingsStore.orbitInputMode {
        case .clickAndDrag:
            orbitInteractionState.endPrimaryInteraction(for: ProgramSettingsStore.DragInputMode.clickAndDrag)
        case .clickThenDrag:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard shouldHandleOrbitMotion else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Float(p.x - lastMousePoint.x)
        let dy = Float(p.y - lastMousePoint.y)
        lastMousePoint = p
        guard abs(dx) >= minimumOrbitMotion || abs(dy) >= minimumOrbitMotion else { return }
        inputDelegate?.didDrag(deltaX: dx, deltaY: dy)
    }

    override func mouseMoved(with event: NSEvent) {
        guard ProgramSettingsStore.orbitInputMode == .clickThenDrag,
              orbitInteractionState.isActive(for: ProgramSettingsStore.DragInputMode.clickThenDrag) else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Float(p.x - lastMousePoint.x)
        let dy = Float(p.y - lastMousePoint.y)
        lastMousePoint = p
        guard abs(dx) >= minimumOrbitMotion || abs(dy) >= minimumOrbitMotion else { return }
        inputDelegate?.didDrag(deltaX: dx, deltaY: dy)
    }

    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        unregisterIndirectTouches(matching: .ended, from: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        unregisterIndirectTouches(matching: .cancelled, from: event)
    }

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        registerIndirectTouches(from: event)
    }

    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        registerIndirectTouches(from: event)
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
        orbitInteractionState.isActive(for: ProgramSettingsStore.orbitInputMode)
    }

    private func registerIndirectTouches(from event: NSEvent) {
        guard ProgramSettingsStore.orbitInputMode == .clickThenDrag else { return }
        let touchingTouches = event.touches(matching: .touching, in: self).filter { $0.type == .indirect }
        orbitInteractionState.registerIndirectTouches(touchingTouches.map { ObjectIdentifier($0.identity) })
    }

    private func unregisterIndirectTouches(matching phase: NSTouch.Phase, from event: NSEvent) {
        let indirectTouches = event.touches(matching: phase, in: self).filter { $0.type == .indirect }
        guard ProgramSettingsStore.orbitInputMode == .clickThenDrag else { return }
        _ = orbitInteractionState.unregisterIndirectTouches(
            indirectTouches.map { ObjectIdentifier($0.identity) },
            isPrimaryButtonPressed: (NSEvent.pressedMouseButtons & 1) != 0
        )
    }

    private func disarmOrbit() {
        orbitInteractionState.reset()
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
private final class WindowLifecycleObserver {
    weak var coordinator: MetalViewportCoordinator?
    weak var window: NSWindow?

    private var didBecomeKeyObserver: NSObjectProtocol?
    private var didDeminiaturizeObserver: NSObjectProtocol?
    private var willCloseObserver: NSObjectProtocol?

    func bind(to nextWindow: NSWindow?) {
        guard window !== nextWindow else { return }
        unbind()
        guard let nextWindow else { return }

        window = nextWindow
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nextWindow,
            queue: .main
        ) { [weak coordinator] _ in
            Task { @MainActor in
                coordinator?.windowDidBecomeActive()
            }
        }
        didDeminiaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: nextWindow,
            queue: .main
        ) { [weak coordinator] _ in
            Task { @MainActor in
                coordinator?.windowDidBecomeActive()
            }
        }
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nextWindow,
            queue: .main
        ) { [weak coordinator] _ in
            Task { @MainActor in
                coordinator?.windowWillClose()
            }
        }

        coordinator?.windowDidBecomeActive()
    }

    func unbind() {
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
            self.didBecomeKeyObserver = nil
        }
        if let didDeminiaturizeObserver {
            NotificationCenter.default.removeObserver(didDeminiaturizeObserver)
            self.didDeminiaturizeObserver = nil
        }
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
            self.willCloseObserver = nil
        }
        window = nil
    }
}

@MainActor
final class MetalViewportCoordinator: NSObject, InputMTKViewDelegate {
    var session: SimulationSession?
    var renderer: Renderer?
    fileprivate weak var metalView: InputMTKView?
    fileprivate weak var axisHostView: NSHostingView<ViewportAxisIndicator>?
    fileprivate let axisModel = ViewportAxisModel()
    fileprivate var errorSink: (@MainActor (String?) -> Void)?
    fileprivate let windowLifecycleObserver = WindowLifecycleObserver()
    private var isViewportAttached = false
    fileprivate var lastAppliedTransportState: SimulationTransportState?

    override init() {
        super.init()
        windowLifecycleObserver.coordinator = self
    }

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

    func tearDownViewport() {
        renderer?.commitCameraState()
        if isViewportAttached {
            session?.detachViewport()
            isViewportAttached = false
        }
        windowLifecycleObserver.unbind()
        metalView?.isPaused = true
        metalView = nil
        axisHostView = nil
    }

    func windowDidBecomeActive() {
        guard !isViewportAttached else { return }
        isViewportAttached = true
        session?.attachViewport()
    }

    func windowWillClose() {
        renderer?.commitCameraState()
        guard isViewportAttached else { return }
        isViewportAttached = false
        session?.detachViewport()
        NotificationCenter.default.post(name: .rebuildViewport, object: nil)
    }
}

struct MetalViewportView: NSViewRepresentable {
    let session: SimulationSession
    let viewportStateStore: MainWindowViewportStateStore
    let transportState: SimulationTransportState
    let diagnosticsStore: MainWindowDiagnosticsStore
    let debugSettingsStore: MainWindowDebugSettingsStore

    func makeCoordinator() -> MetalViewportCoordinator {
        MetalViewportCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        let metalView = InputMTKView(frame: .zero, device: session.device)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = 60

        context.coordinator.axisModel.cameraState = session.viewportState.camera
        let axisHostView = NSHostingView(
            rootView: ViewportAxisIndicator(model: context.coordinator.axisModel, debugSettingsStore: debugSettingsStore) {
                context.coordinator.didPressReset()
            }
        )
        axisHostView.translatesAutoresizingMaskIntoConstraints = false
        axisHostView.setFrameSize(NSSize(width: 72, height: 72))
        axisHostView.wantsLayer = true
        axisHostView.layer?.backgroundColor = NSColor.clear.cgColor

        let renderer: Renderer
        do {
            renderer = try Renderer(
                mtkView: metalView,
                session: session,
                viewportStateStore: viewportStateStore,
                cameraStateSink: { [weak coordinator = context.coordinator] cameraState in
                    coordinator?.axisModel.cameraState = cameraState
                }
            )
        } catch {
            diagnosticsStore.updateViewportRuntimeError(error.localizedDescription)
            return container
        }
        context.coordinator.renderer = renderer
        context.coordinator.session = session
        context.coordinator.metalView = metalView
        context.coordinator.axisHostView = axisHostView
        context.coordinator.errorSink = { [weak diagnosticsStore] error in
            diagnosticsStore?.updateViewportRuntimeError(error)
        }
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
        if let metalView = nsView.subviews.compactMap({ $0 as? InputMTKView }).first {
            context.coordinator.metalView = metalView
            if metalView.delegate == nil, let renderer = context.coordinator.renderer {
                metalView.delegate = renderer
            }
            if metalView.inputDelegate == nil {
                metalView.inputDelegate = context.coordinator
            }
            context.coordinator.windowLifecycleObserver.bind(to: metalView.window)
            if metalView.window != nil {
                metalView.isPaused = false
                metalView.enableSetNeedsDisplay = false
            }
        }
        if context.coordinator.lastAppliedTransportState != transportState {
            if transportState == .running || transportState == .paused || transportState == .stopped {
                context.coordinator.renderer?.commitCameraState()
            }
            context.coordinator.lastAppliedTransportState = transportState
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: MetalViewportCoordinator) {
        coordinator.tearDownViewport()
    }
}

@MainActor
private final class ViewportAxisModel: ObservableObject {
    @Published var cameraState = ViewportCameraState()
}

private struct ViewportAxisIndicator: View {
    @ObservedObject var model: ViewportAxisModel
    @ObservedObject var debugSettingsStore: MainWindowDebugSettingsStore
    let onReset: () -> Void

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
        .contentShape(Rectangle())
        .onTapGesture(perform: onReset)
    }

    private var projectedAxes: [AxisProjection] {
        let cameraState = model.cameraState
        let forward = CameraMath.forwardVector(yaw: cameraState.yaw, pitch: cameraState.pitch)
        let right = CameraMath.rightVector(yaw: cameraState.yaw, pitch: cameraState.pitch)
        let up = CameraMath.upVector(yaw: cameraState.yaw, pitch: cameraState.pitch)
        let center = CGPoint(x: 36, y: 36)
        let scale: Float = 22
        let perspectiveDistance = Float(debugSettingsStore.snapshot.compassPerspectiveDistance)
        let perspectiveStrength = Float(debugSettingsStore.snapshot.compassPerspectiveStrength)

        // TODO: Temporary compass-only Z-up correction. The underlying renderer/camera stack
        // is still Y-up and needs a proper engine-wide refactor so the whole program uses Z-up.
        let worldAxes: [(String, Color, SIMD3<Float>)] = [
            ("X", .red, SIMD3<Float>(1, 0, 0)),
            ("Y", .green, SIMD3<Float>(0, 0, 1)),
            ("Z", .blue, SIMD3<Float>(0, 1, 0)),
        ]

        return worldAxes
            .map { label, color, axis in
                let cameraSpace = SIMD3<Float>(
                    simd_dot(right, axis),
                    simd_dot(up, axis),
                    simd_dot(forward, axis)
                )
                let divisor = max(0.8, perspectiveDistance - cameraSpace.z * perspectiveStrength)
                let projectedX = cameraSpace.x * scale / divisor
                let projectedY = cameraSpace.y * scale / divisor
                let endpoint = CGPoint(
                    x: center.x + CGFloat(projectedX),
                    y: center.y - CGFloat(projectedY)
                )
                return AxisProjection(label: label, color: color, endpoint: endpoint, depth: cameraSpace.z)
            }
            .sorted { $0.depth < $1.depth }
    }
}
