// App/Source/MPVMetalLayer.swift
import Foundation
import AppKit

/// CAMetalLayer subclass for libmpv's vo=gpu-next + gpu-context=moltenvk path.
/// Two workarounds adapted from MPVKit's official Metal demo:
///
/// 1. drawableSize setter filters out 1×1 — MoltenVK sometimes sets the
///    drawableSize to 1×1 during its presentation completion path, which
///    causes flicker and can leave the layer permanently at 1×1.
///    https://github.com/mpv-player/mpv/pull/13651
///
/// 2. wantsExtendedDynamicRangeContent setter trampolines onto the main
///    thread because activating screen EDR mode only works from the main
///    thread; mpv's render thread will set this from the wrong queue.
///    Uses DispatchQueue.main.async (NOT .sync as in the demo) — .sync can
///    deadlock if main is mid-`mpv_*` API call when the render thread sets
///    EDR. Value write is idempotent; no return needed.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.async {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}
