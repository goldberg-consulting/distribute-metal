import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            DiscoveryService.shared.startBrowsing()
            DiscoveryService.shared.startAdvertising()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiscoveryService.shared.stopBrowsing()
        DiscoveryService.shared.stopAdvertising()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
