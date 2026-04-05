import SwiftUI

@main
struct DistributeMetalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var discovery = DiscoveryService.shared
    @StateObject private var orchestrator = JobOrchestrator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(discovery)
                .environmentObject(orchestrator)
        } label: {
            Text("DM")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .help("DistributeMetal")
        }
        .menuBarExtraStyle(.window)
    }
}
