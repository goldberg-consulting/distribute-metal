import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            DiscoveryService.shared.startBrowsing()
            DiscoveryService.shared.startAdvertising()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            DiscoveryService.shared.stopBrowsing()
            DiscoveryService.shared.stopAdvertising()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
