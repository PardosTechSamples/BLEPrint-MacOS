import AppKit
import SwiftUI

struct BLEPrintApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("BLEPrint") {
            ContentView().environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About BLEPrint") {
                    let credits = NSAttributedString(string:
                        "Open-source batch label printer over Bluetooth LE.\n\n"
                        + "Compatible with the Nelko® P21 and the Supvan® / Katasymbol E10 (T10/T15 family). "
                        + "“Nelko”, “P21”, “Supvan”, “Katasymbol” and “E10” are trademarks of their respective owners, "
                        + "used only to describe compatibility. BLEPrint is not affiliated with either company.\n\n"
                        + "The Supvan job encoding follows the MIT-licensed supvan-katasymbol-printer-web-ui project "
                        + "(© Katasymbol Web contributors). LZMA via liblzma (0BSD). MIT License.")
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "BLEPrint",
                                                                .applicationVersion: "0.3.0 (Swift)", .credits: credits])
                }
            }
        }
    }
}

// Running the bare executable (swift run / Terminal) needs a regular app with a Dock icon and focus.
NSApplication.shared.setActivationPolicy(.regular)
DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
BLEPrintApp.main()
