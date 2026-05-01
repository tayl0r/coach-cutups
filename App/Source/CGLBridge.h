#ifndef CGLBridge_h
#define CGLBridge_h
#include <dlfcn.h>
// Resolve OpenGL entry points for libmpv's get_proc_address callback.
//
// Why dlsym(RTLD_DEFAULT, name) and not CGLGetProcAddress: despite the v2
// plan's claim, CGLGetProcAddress is not declared in <OpenGL/OpenGL.h> on
// modern macOS SDKs and is not exported from OpenGL.framework's binary
// either (verified against the SDK's tbd and the live framework's exports
// — only CGLGet* symbols like CGLGetVersion/CGLGetParameter are present).
//
// Why dlsym works where CFBundleGetFunctionPointerForName / a non-existent
// CGLGetProcAddress fail: OpenGL.framework does export the 3.x Core Profile
// entry points (glGenVertexArrays, glDrawArrays, etc.) as flat-namespace
// symbols in its binary; dlsym with RTLD_DEFAULT walks the loaded image
// list and finds them. This is the resolver libmpv's own macOS examples
// and downstream embedders use.
static inline void *vc_cgl_get_proc_address(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}
#endif
