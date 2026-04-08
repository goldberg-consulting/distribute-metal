import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var discovery: DiscoveryService
    @EnvironmentObject var orchestrator: JobOrchestrator

    @State private var showAddPeer = false
    @State private var peerActionError: String?

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
        .alert("Peer Action Failed", isPresented: Binding(
            get: { peerActionError != nil },
            set: { if !$0 { peerActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(peerActionError ?? "Unknown error")
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
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            Text("v\(version)")
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

                let readyCount = discovery.discoveredPeers.values.filter { $0.status == .ready }.count
                let total = discovery.discoveredPeers.count
                if total > 0 {
                    Text("\(readyCount)/\(total) ready")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if discovery.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                }

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
                        Text(discovery.isScanning ? "Scanning..." : "No peers found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Press Scan or add manually")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(discovery.discoveredPeers.values).sorted(by: { $0.name < $1.name }), id: \.id) { peer in
                    PeerRow(
                        peer: peer,
                        isBenchmarking: discovery.benchmarkingPeerIDs.contains(peer.id),
                        onBenchmark: {
                            Task {
                                do {
                                    try await discovery.benchmarkPeer(peer)
                                } catch {
                                    peerActionError = error.localizedDescription
                                }
                            }
                        }
                    ) {
                        discovery.removePeer(ip: peer.ipAddress)
                    }
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
                VStack(spacing: 6) {
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

                    Button {
                        initJobFromFolder()
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                            Text("New Job from Folder...")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                discovery.scan()
            } label: {
                HStack(spacing: 4) {
                    if discovery.isScanning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Scan")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(discovery.isScanning)

            Spacer()

            Button {
                discovery.probeAllPeers()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
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
                peerActionError = error.localizedDescription
            }
        }
    }

    private func initJobFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a training project folder"
        panel.prompt = "Generate YAML"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let yaml = try YAMLGenerator.generate(from: url)
                    let yamlURL = url.appendingPathComponent("distribute-metal.yaml")
                    try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
                    _ = try orchestrator.createJob(from: yamlURL, peers: Array(discovery.discoveredPeers.values))
                } catch {
                    peerActionError = error.localizedDescription
                }
            }
        }
    }
}
