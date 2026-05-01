import Foundation
import AppKit
import Metal
import OpenGL.GL3
import IOSurface
import CoreVideo

/// Owns the GL context, IOSurface, GL texture, GL FBO, and Metal texture
/// that bridge mpv's GL output to a CAMetalLayer drawable. One bridge per
/// MPVRenderingNSView. Not thread-safe; the owner serializes access via the
/// view's renderLock-equivalent.
final class GLMetalBridge {
    let glContext: NSOpenGLContext
    let device: MTLDevice
    private(set) var surface: IOSurfaceRef?
    private(set) var glTexture: GLuint = 0
    private(set) var fbo: GLuint = 0
    private(set) var metalTexture: MTLTexture?
    private(set) var surfaceWidth: Int = 0
    private(set) var surfaceHeight: Int = 0

    init(device: MTLDevice) throws {
        self.device = device
        // Note: use NSOpenGLPixelFormatAttribute(...) to cast each element — there
        // is no NSOpenGLPFAOpenGLProfile_t symbol (Phase 0.2 found this typo).
        let attribs: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAllowOfflineRenderers),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), NSOpenGLPixelFormatAttribute(32),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            0,
        ]
        guard let pf = NSOpenGLPixelFormat(attributes: attribs),
              let ctx = NSOpenGLContext(format: pf, share: nil) else {
            throw GLMetalBridgeError.glContextFailed
        }
        self.glContext = ctx
    }

    func resize(to size: CGSize) throws {
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        if w == surfaceWidth, h == surfaceHeight, surface != nil { return }

        teardownGLObjects()

        let props: [IOSurfacePropertyKey: Any] = [
            .width: w, .height: h, .bytesPerElement: 4,
            .pixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
        ]
        guard let s = IOSurface(properties: props) else { throw GLMetalBridgeError.iosurfaceFailed }
        let cfSurface = s as IOSurfaceRef  // Phase 0.2 found this is the right bridge form
        self.surface = cfSurface

        glContext.makeCurrentContext()
        glGenTextures(1, &glTexture)
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), glTexture)
        let cgl = CGLGetCurrentContext()!
        let r = CGLTexImageIOSurface2D(
            cgl, GLenum(GL_TEXTURE_RECTANGLE),
            GLenum(GL_RGBA), GLsizei(w), GLsizei(h),
            GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
            cfSurface, 0
        )
        guard r == kCGLNoError else { throw GLMetalBridgeError.cglTexImageFailed(Int(r.rawValue)) }

        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_RECTANGLE), glTexture, 0
        )
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            throw GLMetalBridgeError.fboIncomplete
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        guard let mtl = device.makeTexture(descriptor: desc, iosurface: cfSurface, plane: 0) else {
            throw GLMetalBridgeError.metalTextureFailed
        }
        self.metalTexture = mtl
        self.surfaceWidth = w
        self.surfaceHeight = h
    }

    func clearTo(red: Float, green: Float, blue: Float, alpha: Float) {
        glContext.makeCurrentContext()
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glViewport(0, 0, GLsizei(surfaceWidth), GLsizei(surfaceHeight))
        glClearColor(GLfloat(red), GLfloat(green), GLfloat(blue), GLfloat(alpha))
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    }

    private func teardownGLObjects() {
        glContext.makeCurrentContext()
        if fbo != 0 { glDeleteFramebuffers(1, &fbo); fbo = 0 }
        if glTexture != 0 { glDeleteTextures(1, &glTexture); glTexture = 0 }
        metalTexture = nil
        surface = nil
    }

    deinit { teardownGLObjects() }
}

enum GLMetalBridgeError: Error {
    case glContextFailed
    case iosurfaceFailed
    case cglTexImageFailed(Int)
    case fboIncomplete
    case metalTextureFailed
}
