import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentProcessService.shared.start()
        DiscoveryService.shared.startBrowsing()
        DiscoveryService.shared.startAdvertising()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiscoveryService.shared.stopBrowsing()
        DiscoveryService.shared.stopAdvertising()
        AgentProcessService.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
