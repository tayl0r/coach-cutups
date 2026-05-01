import SwiftUI
import AppKit
import Metal
import QuartzCore
import OpenGL.GL3

/// SwiftUI representable that drives a GLMetalBridge with clearTo(red,green,blue,alpha)
/// from a CVDisplayLink. Used to verify the GL→IOSurface→Metal hand-off
/// independent of mpv. Permanent debug fixture — exposed via the Debug menu.
struct GLBridgeDemoRepresentable: NSViewRepresentable {
    let r: Float
    let g: Float
    let b: Float
    func makeNSView(context: Context) -> GLBridgeDemoNSView { GLBridgeDemoNSView(r: r, g: g, b: b) }
    func updateNSView(_ nsView: GLBridgeDemoNSView, context: Context) {}
}

final class GLBridgeDemoNSView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bridge: GLMetalBridge
    private var displayLink: CVDisplayLink?
    private let r: Float; private let g: Float; private let b: Float

    init(r: Float, g: Float, b: Float) {
        self.r = r; self.g = g; self.b = b
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { fatalError("Metal device unavailable") }
        self.device = dev
        self.commandQueue = q
        self.bridge = (try? GLMetalBridge(device: dev))!
        super.init(frame: .zero)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let s = window?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = CGSize(width: max(1, newSize.width * s), height: max(1, newSize.height * s))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                guard let self else { return kCVReturnSuccess }
                let size = self.metalLayer.drawableSize
                guard size.width > 0, size.height > 0 else { return kCVReturnSuccess }
                try? self.bridge.resize(to: size)
                self.bridge.clearTo(red: self.r, green: self.g, blue: self.b, alpha: 1.0)
                glFlush()
                self.bridge.present(into: self.metalLayer, commandQueue: self.commandQueue)
                return kCVReturnSuccess
            }
            _ = CVDisplayLinkStart(link)
            self.displayLink = link
        }
    }

    deinit {
        if let link = displayLink { CVDisplayLinkStop(link) }
    }
}
