import SwiftUI
import AppKit
import Metal
import QuartzCore
import Libmpv

/// NSView that hosts a CAMetalLayer and drives an mpv render context.
/// Phase 1 bring-up creates a private mpv_handle inside this view; Phase
/// 3 refactors `attach(player:)` to delegate to a shared MPVSourcePlayer.
final class MPVRenderingNSView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// Phase-1-private handle. Phase 3.5 replaces with shared MPVSourcePlayer.
    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var displayLink: CVDisplayLink?
    private let renderLock = NSLock()

    override init(frame: NSRect) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            fatalError("Metal device unavailable")
        }
        self.device = dev
        self.commandQueue = q
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    /// Phase 1 bring-up entry point.
    func bringUp(filePath: String, hwdec: String, audioOff: Bool = false) throws {
        let h = mpv_create()
        guard let h else { throw NSError(domain: "MPV", code: -1) }

        for (k, v) in [
            ("vo", "libmpv"),
            ("hwdec", hwdec),
            ("prefetch-playlist", "yes"),
            ("keep-open", "yes"),
            ("keep-open-pause", "no"),
            ("pause", "no"),
            // Phase 1 only: vd=info lets the "Using video decoder: hevc"
            // log line through for gate (e). MPVSourcePlayer (Phase 3)
            // pins all=warn for production.
            ("msg-level", "all=warn,vd=info"),
            ("audio-display", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("target-colorspace-hint", "yes"),
        ] {
            mpv_set_option_string(h, k, v)
        }
        if audioOff {
            // For the debug window — avoid fighting CoreAudio with the
            // production source player when both are open simultaneously.
            mpv_set_option_string(h, "ao", "null")
        }

        // Phase 1 bring-up: surface log lines to Console.app so gate (e)
        // can verify "Using hardware decoding (videotoolbox)".
        mpv_request_log_messages(h, "info")

        let rc = mpv_initialize(h)
        guard rc >= 0 else {
            mpv_destroy(h)
            throw NSError(domain: "MPV", code: Int(rc))
        }
        self.mpv = h
        try attachRenderContext()

        // Single loadfile — bring-up plays one file.
        runCommand(handle: h, args: ["loadfile", filePath, "replace"])
    }

    private func attachRenderContext() throws {
        renderLock.lock(); defer { renderLock.unlock() }
        guard let mpv else { return }

        // MPV_RENDER_PARAM_API_TYPE wants a `char *` pointing to "sw".
        // We hold the C buffer here so the pointer stays alive across
        // the create call.
        var apiTypeBuf = Array("sw".utf8CString)
        var advancedControl: Int32 = 0

        let rc: CInt = apiTypeBuf.withUnsafeMutableBufferPointer { apiBuf -> CInt in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                 data: UnsafeMutableRawPointer(apiBuf.baseAddress)),
                mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL,
                                 data: withUnsafeMutableBytes(of: &advancedControl) { $0.baseAddress }),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            var ctx: OpaquePointer?
            let r = params.withUnsafeMutableBufferPointer {
                mpv_render_context_create(&ctx, mpv, $0.baseAddress)
            }
            if r >= 0, let ctx { self.renderContext = ctx }
            return r
        }
        guard rc >= 0, renderContext != nil else { throw NSError(domain: "MPVRender", code: Int(rc)) }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                self?.renderTick()
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            self.displayLink = link
        }
    }

    private func renderTick() {
        guard renderLock.try() else { return }
        defer { renderLock.unlock() }
        guard let renderContext else { return }

        let drawableSize = metalLayer.drawableSize
        let w = Int32(drawableSize.width)
        let h = Int32(drawableSize.height)
        guard w > 0, h > 0 else { return }

        let bytesPerRow = Int(w) * 4
        let bufferSize = bytesPerRow * Int(h)
        let pixelBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { pixelBuffer.deallocate() }

        var size: [Int32] = [w, h]
        var stride = Int(bytesPerRow)
        var format = "bgr0".utf8CString

        format.withUnsafeMutableBufferPointer { fmtBuf in
            size.withUnsafeMutableBufferPointer { sizeBuf in
                withUnsafeMutablePointer(to: &stride) { stridePtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE,
                                         data: UnsafeMutableRawPointer(sizeBuf.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT,
                                         data: UnsafeMutableRawPointer(fmtBuf.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE,
                                         data: UnsafeMutableRawPointer(stridePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER,
                                         data: pixelBuffer),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = params.withUnsafeMutableBufferPointer {
                        mpv_render_context_render(renderContext, $0.baseAddress)
                    }
                }
            }
        }

        guard let drawable = metalLayer.nextDrawable() else { return }
        drawable.texture.replace(
            region: MTLRegionMake2D(0, 0, Int(w), Int(h)),
            mipmapLevel: 0,
            withBytes: pixelBuffer,
            bytesPerRow: bytesPerRow
        )
        if let cmdBuf = commandQueue.makeCommandBuffer() {
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { tearDown() }
    }

    private func tearDown() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        renderLock.lock()
        if let ctx = renderContext {
            mpv_render_context_free(ctx)
            renderContext = nil
        }
        renderLock.unlock()
        if let h = mpv {
            mpv_terminate_destroy(h)
            mpv = nil
        }
    }

    deinit { tearDown() }
}

fileprivate func runCommand(handle: OpaquePointer, args: [String]) {
    var cstrings = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    defer { cstrings.forEach { if let p = $0 { free(p) } } }
    cstrings.withUnsafeMutableBufferPointer { buf in
        let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        _ = mpv_command(handle, p)
    }
}

/// SwiftUI bridge for the bring-up window.
struct MPVDebugRepresentable: NSViewRepresentable {
    let filePath: String
    let hwdec: String
    let overlayTint: Bool
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        do { try v.bringUp(filePath: filePath, hwdec: hwdec, audioOff: true) }
        catch { NSLog("[MPV-debug] bringUp failed: \(error)") }
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {}
}
