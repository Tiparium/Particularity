import AppKit
import MetalKit
import SwiftUI

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

protocol InputMTKViewDelegate: AnyObject {
    func didPressKey(_ key: String)
    func didReleaseKey(_ key: String)
    func didDrag(deltaX: Float, deltaY: Float)
    func didScroll(deltaY: Float)
    func didMagnify(_ magnification: Float)
    func didPressReset()
}

final class MetalViewportCoordinator: NSObject, InputMTKViewDelegate {
    var renderer: Renderer?

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
}

struct MetalViewportView: NSViewRepresentable {
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
        metalView.clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = 60

        guard let renderer = Renderer(mtkView: metalView) else {
            return container
        }
        context.coordinator.renderer = renderer
        metalView.delegate = renderer
        metalView.inputDelegate = context.coordinator

        container.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: container.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
