import SwiftUI
import AVFoundation

/// Top-level "Devices" menu in the macOS menu bar. Each submenu is an inline
/// Picker bound to `DeviceCatalog.selected{Camera,Mic}ID`, so the current
/// selection renders with a checkmark next to it (QuickTime / Photo Booth
/// convention). Both submenus disable while a recording is in progress —
/// device swaps mid-recording are refused at the capture layer too, but the
/// menu affordance is the user-visible signal.
struct DevicesCommands: Commands {
    @Bindable var catalog: DeviceCatalog

    var body: some Commands {
        CommandMenu("Devices") {
            Menu("Camera") {
                Picker("Camera", selection: $catalog.selectedCameraID) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    ForEach(catalog.availableCameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(catalog.lockedByRecording)

            Menu("Microphone") {
                Picker("Microphone", selection: $catalog.selectedMicID) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    ForEach(catalog.availableMicrophones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(catalog.lockedByRecording)
        }
    }
}
