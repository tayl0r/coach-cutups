import SwiftUI

/// Phase 1 / D6 gate. Standalone window that loads the test file through
/// the new mpv pipeline. The hwdec picker drives gate (a); the overlay
/// toggle drives gate (d). Both are permanent debug affordances.
struct MPVDebugWindow: View {
    @State private var hwdec: String = "videotoolbox"
    @State private var filePath: String =
        "/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4"
    @State private var overlayTint: Bool = false
    @State private var revision: Int = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("File path", text: $filePath)
                Picker("hwdec", selection: $hwdec) {
                    Text("videotoolbox").tag("videotoolbox")
                    Text("no").tag("no")
                    Text("auto-safe").tag("auto-safe")
                }
                .pickerStyle(.menu)
                Toggle("Overlay tint", isOn: $overlayTint)
                Button("Reload") { revision &+= 1 }
            }
            .padding(.horizontal, 8).padding(.top, 8)

            ZStack {
                MPVDebugRepresentable(filePath: filePath, hwdec: hwdec, overlayTint: overlayTint)
                    .id(revision)   // recreate the NSView (and mpv handle) on Reload
                if overlayTint {
                    Color.red.opacity(0.3).allowsHitTesting(false)
                    Text("Overlay test")
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(6)
                }
            }
            .frame(minWidth: 640, minHeight: 360)
        }
        .frame(minWidth: 800, minHeight: 480)
        .background(WindowAccessor { window in
            window.isRestorable = false
        })
    }
}

/// Locates the SwiftUI window's underlying NSWindow and runs a closure
/// against it. Used here to mark the bring-up window non-restorable so
/// it doesn't auto-reopen at next app launch.
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            if let window = v?.window {
                configure(window)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
