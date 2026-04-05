import Foundation
import Network
import Combine
import os.log

@MainActor
final class DiscoveryService: ObservableObject {
    static let shared = DiscoveryService()

    private let logger = Logger(subsystem: "one.measured.distribute-metal", category: "Discovery")
    private let serviceType = "_distributemetal._tcp"
    private let agentPort: NWEndpoint.Port = 8477

    @Published var discoveredPeers: [String: Peer] = [:]
    @Published var isScanning = false

    private var browser: NWBrowser?
    private var localBrowser: NWBrowser?
    private var dnssdProcess: Process?
    private let queue = DispatchQueue(label: "one.measured.distribute-metal.discovery", qos: .userInitiated)
    private let client = AgentClient()
    private var probeTask: Task<Void, Never>?

    private init() {}

    // MARK: - Advertise

    func startAdvertising() {
        guard dnssdProcess == nil else { return }

        let name = NetworkUtils.sanitizedComputerName
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let ip = NetworkUtils.localIPAddress ?? "unknown"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = [
            "-R", name, serviceType, "local.", "\(agentPort)",
            "ver=\(version)",
            "arch=arm64",
            "ip=\(ip)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            dnssdProcess = process
            logger.info("Advertising as \(name) on \(self.serviceType)")
        } catch {
            logger.error("Failed to start dns-sd: \(error.localizedDescription)")
        }
    }

    func stopAdvertising() {
        if let p = dnssdProcess, p.isRunning { p.terminate() }
        dnssdProcess = nil
        logger.info("Stopped advertising")
    }

    // MARK: - Browse

    func startBrowsing() {
        stopBrowsing()
        isScanning = true

        let params = NWParameters()
        params.includePeerToPeer = true

        for domain in ["local.", ""] {
            let actualDomain = domain.isEmpty ? nil : domain
            let b = NWBrowser(for: .bonjour(type: serviceType, domain: actualDomain), using: params)

            b.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.logger.info("Browser ready (domain: \(domain.isEmpty ? "default" : domain))")
                case .failed(let err):
                    self?.logger.error("Browser failed: \(err.localizedDescription)")
                default:
                    break
                }
            }

            b.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    self?.handleBrowseResults(results)
                }
            }

            b.start(queue: queue)

            if domain == "local." {
                localBrowser = b
            } else {
                browser = b
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(5))
            isScanning = false
        }
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        localBrowser?.cancel()
        localBrowser = nil
    }

    // MARK: - Full scan (re-discover + probe all)

    func scan() {
        stopBrowsing()
        startBrowsing()
        startAdvertising()
        probeAllPeers()
    }

    // MARK: - Probe agents via HTTP

    func probeAllPeers() {
        probeTask?.cancel()
        probeTask = Task {
            await withTaskGroup(of: (String, Peer?).self) { group in
                for (ip, peer) in discoveredPeers {
                    group.addTask { [client] in
                        do {
                            let status = try await client.fetchStatus(from: peer)
                            var updated = peer
                            updated.status = Self.mapAgentState(status.state)
                            updated.arch = status.arch
                            updated.chip = status.chip
                            updated.memoryGB = status.memoryGB
                            updated.macOSVersion = status.macOSVersion
                            updated.agentVersion = status.agentVersion
                            updated.mcclVersion = status.mcclVersion
                            updated.pythonVersion = status.pythonVersion
                            updated.uvAvailable = status.uvAvailable
                            updated.freeDiskGB = status.freeDiskGB
                            updated.lastSeen = Date()
                            return (ip, updated)
                        } catch {
                            var updated = peer
                            updated.status = .offline
                            return (ip, updated)
                        }
                    }
                }
                for await (ip, peer) in group {
                    if let peer {
                        discoveredPeers[ip] = peer
                    }
                }
            }
        }
    }

    func probePeer(_ peer: Peer) async -> Peer {
        do {
            let status = try await client.fetchStatus(from: peer)
            var updated = peer
            updated.status = Self.mapAgentState(status.state)
            updated.arch = status.arch
            updated.chip = status.chip
            updated.memoryGB = status.memoryGB
            updated.macOSVersion = status.macOSVersion
            updated.agentVersion = status.agentVersion
            updated.mcclVersion = status.mcclVersion
            updated.pythonVersion = status.pythonVersion
            updated.uvAvailable = status.uvAvailable
            updated.freeDiskGB = status.freeDiskGB
            updated.lastSeen = Date()
            return updated
        } catch {
            var updated = peer
            updated.status = .offline
            return updated
        }
    }

    private nonisolated static func mapAgentState(_ state: AgentState) -> PeerStatus {
        switch state {
        case .idle, .ready, .cleaned:
            return .ready
        case .syncing, .provisioning, .launching, .running:
            return .busy
        case .failed:
            return .offline
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        let localIP = NetworkUtils.localIPAddress ?? ""

        for result in results {
            guard case .service(let name, let type, _, _) = result.endpoint else { continue }
            guard type.contains(serviceType) else { continue }

            var txtFields: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                for (key, value) in record.dictionary {
                    txtFields[key] = value
                }
            }

            let ip = txtFields["ip"] ?? "unknown"
            let ver = txtFields["ver"]

            if ip == localIP || ip == "unknown" { continue }

            if discoveredPeers[ip] != nil { continue }

            let peer = Peer(
                id: UUID(),
                name: name,
                hostname: "\(name).local",
                ipAddress: ip,
                port: Int(agentPort.rawValue),
                status: .discovered,
                agentVersion: ver,
                lastSeen: Date()
            )

            discoveredPeers[ip] = peer
            logger.info("Found peer: \(name) at \(ip)")

            Task {
                let probed = await probePeer(peer)
                discoveredPeers[ip] = probed
            }
        }
    }

    // MARK: - Manual add

    func addManualPeer(name: String, ip: String, port: Int = 8477) {
        let peer = Peer.manual(name: name, ip: ip, port: port)
        discoveredPeers[ip] = peer

        Task {
            let probed = await probePeer(peer)
            discoveredPeers[ip] = probed
        }
    }

    func removePeer(ip: String) {
        discoveredPeers.removeValue(forKey: ip)
    }
}

// MARK: - TXT record helpers

private extension NWTXTRecord {
    var dictionary: [(key: String, value: String)] {
        var result: [(String, String)] = []
        self.forEach { element in
            if case .string(let str) = element.value {
                result.append((element.key, str))
            }
        }
        return result
    }
}
