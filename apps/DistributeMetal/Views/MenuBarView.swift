import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var discovery: DiscoveryService
    @EnvironmentObject var orchestrator: JobOrchestrator

    @State private var showAddPeer = false
    @State private var showJobPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            peersList
            Divider()
            jobSection
            Divider()
            footer
        }
        .frame(width: 360)
        .sheet(isPresented: $showAddPeer) {
            AddPeerSheet(discovery: discovery)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("measured.one")
                    .font(.headline)
                Text("distribute-metal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v0.1.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    // MARK: - Peers

    private var peersList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Peers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showAddPeer = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            if discovery.discoveredPeers.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("No peers found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Add manually or wait for discovery")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(discovery.discoveredPeers.values), id: \.id) { peer in
                    PeerRow(peer: peer)
                }
            }
        }
        .padding()
    }

    // MARK: - Job

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Job")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if let job = orchestrator.currentJob {
                JobStatusView(job: job)
            } else {
                Button {
                    openJobYAML()
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        Text("Open distribute-metal.yaml...")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                discovery.startBrowsing()
                discovery.startAdvertising()
            } label: {
                Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func openJobYAML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a distribute-metal.yaml file"

        if panel.runModal() == .OK, let url = panel.url {
            let peers = Array(discovery.discoveredPeers.values)
            do {
                _ = try orchestrator.createJob(from: url, peers: peers)
            } catch {
                print("Failed to load job spec: \(error)")
            }
        }
    }
}
