import AppKit
import MetalKit
import SwiftUI

private final class InputMTKView: MTKView {
    weak var inputDelegate: InputMTKViewDelegate?
    private var lastMousePoint: NSPoint = .zero
    private var isDraggingOrbit = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDraggingOrbit = true
        lastMousePoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingOrbit = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingOrbit else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Float(p.x - lastMousePoint.x)
        let dy = Float(p.y - lastMousePoint.y)
        lastMousePoint = p
        inputDelegate?.didDrag(deltaX: dx, deltaY: dy)
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
        renderer?.dollyByScroll(deltaY: deltaY)
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
