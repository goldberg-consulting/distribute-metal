import Foundation
import Network
import Combine
import os.log

/// Tracks Bonjour-visible peers, probes the agent on each peer, and records
/// link benchmark results for the menu bar UI.
///
/// Discovery keys peers by either TXT-provided IP or Bonjour hostname so a row
/// can survive transitions from hostname-only discovery to a concrete address.
@MainActor
final class DiscoveryService: ObservableObject {
    static let shared = DiscoveryService()

    private let logger = Logger(subsystem: "one.measured.distribute-metal", category: "Discovery")
    private let serviceType = "_distributemetal._tcp"
    private let agentPort: NWEndpoint.Port = 8477

    @Published var discoveredPeers: [String: Peer] = [:]
    @Published var isScanning = false
    @Published var benchmarkingPeerIDs: Set<UUID> = []

    private var browser: NWBrowser?
    private var localBrowser: NWBrowser?
    private var dnssdProcess: Process?
    private let queue = DispatchQueue(label: "one.measured.distribute-metal.discovery", qos: .userInitiated)
    private let client = AgentClient()
    private var probeTask: Task<Void, Never>?
    private var inFlightProbeKeys: Set<String> = []

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

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        for domain in ["local.", ""] {
            let actualDomain = domain.isEmpty ? nil : domain
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: actualDomain), using: params)

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
                            return (ip, Self.updatedPeer(from: status, peer: peer))
                        } catch {
                            return (ip, Self.unreachablePeer(from: peer, error: error))
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
            return Self.updatedPeer(from: status, peer: peer)
        } catch {
            return Self.unreachablePeer(from: peer, error: error)
        }
    }

    private nonisolated static func mapAgentState(_ state: AgentState) -> PeerStatus {
        switch state {
        case .idle, .ready, .cleaned:
            return .ready
        case .syncing, .provisioning, .launching, .running:
            return .busy
        case .failed:
            return .agentFailed
        }
    }

    private nonisolated static func updatedPeer(from status: AgentStatusResponse, peer: Peer) -> Peer {
        var updated = peer
        updated.status = mapAgentState(status.state)
        updated.arch = status.arch
        updated.chip = status.chip
        updated.memoryGB = status.memoryGB
        updated.macOSVersion = status.macOSVersion
        updated.agentVersion = status.agentVersion
        updated.mcclVersion = status.mcclVersion
        updated.pythonVersion = status.pythonVersion
        updated.uvAvailable = status.uvAvailable
        updated.freeDiskGB = status.freeDiskGB
        updated.statusDetail = status.state == .failed ? "agent reported failure" : nil
        updated.lastSeen = Date()
        return updated
    }

    private nonisolated static func unreachablePeer(from peer: Peer, error: Error) -> Peer {
        var updated = peer
        updated.status = .unreachable
        updated.statusDetail = probeFailureDescription(error)
        return updated
    }

    private nonisolated static func probeFailureDescription(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost:
                return "cannot connect to agent"
            case .timedOut:
                return "agent probe timed out"
            case .notConnectedToInternet:
                return "network unavailable"
            case .networkConnectionLost:
                return "network connection lost"
            default:
                return urlError.localizedDescription
            }
        }
        if let clientError = error as? AgentClientError {
            return clientError.localizedDescription
        }
        return error.localizedDescription
    }

    private func normalizedAddress(_ address: String?) -> String? {
        guard let address else { return nil }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "unknown" else { return nil }
        return trimmed
    }

    private func peerKey(for address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func existingPeerKey(for hostname: String, ip: String?) -> String? {
        let hostnameKey = peerKey(for: hostname)
        if discoveredPeers[hostnameKey] != nil {
            return hostnameKey
        }

        if let ip {
            let ipKey = peerKey(for: ip)
            if discoveredPeers[ipKey] != nil {
                return ipKey
            }
        }

        return discoveredPeers.first {
            $0.value.hostname.caseInsensitiveCompare(hostname) == .orderedSame
        }?.key
    }

    private func scheduleProbe(for peer: Peer) {
        let scheduledKey = existingPeerKey(
            for: peer.hostname,
            ip: normalizedAddress(peer.ipAddress)
        ) ?? peerKey(for: peer.ipAddress)

        guard !inFlightProbeKeys.contains(scheduledKey) else { return }
        inFlightProbeKeys.insert(scheduledKey)

        Task {
            defer { inFlightProbeKeys.remove(scheduledKey) }

            let probed = await probePeer(peer)
            let currentKey = existingPeerKey(
                for: probed.hostname,
                ip: normalizedAddress(probed.ipAddress)
            ) ?? peerKey(for: probed.ipAddress)
            discoveredPeers[currentKey] = mergedPeer(current: discoveredPeers[currentKey], with: probed)
        }
    }

    private func mergedPeer(current: Peer?, with probed: Peer) -> Peer {
        guard var current else { return probed }

        current.status = probed.status
        current.arch = probed.arch ?? current.arch
        current.chip = probed.chip ?? current.chip
        current.memoryGB = probed.memoryGB ?? current.memoryGB
        current.macOSVersion = probed.macOSVersion ?? current.macOSVersion
        current.agentVersion = probed.agentVersion ?? current.agentVersion
        current.mcclVersion = probed.mcclVersion ?? current.mcclVersion
        current.pythonVersion = probed.pythonVersion ?? current.pythonVersion
        current.uvAvailable = probed.uvAvailable ?? current.uvAvailable
        current.freeDiskGB = probed.freeDiskGB ?? current.freeDiskGB
        current.statusDetail = probed.statusDetail
        current.lastSeen = probed.lastSeen
        return current
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        let localIP = normalizedAddress(NetworkUtils.localIPAddress)
        let localName = NetworkUtils.sanitizedComputerName

        for result in results {
            guard case .service(let name, let type, _, _) = result.endpoint else { continue }
            guard type.contains(serviceType) else { continue }
            guard name != localName else { continue }

            let hostname = "\(name).local"
            var txtFields: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                txtFields = record.stringDictionary
            }

            let ip = normalizedAddress(txtFields["ip"])
            let ver = normalizedAddress(txtFields["ver"])
            if let localIP, ip == localIP { continue }

            let address = ip ?? hostname
            let key = peerKey(for: address)
            let previousKey = existingPeerKey(for: hostname, ip: ip) ?? key
            let previousPeer = discoveredPeers[previousKey]
            let shouldProbe = previousPeer == nil
                || previousPeer?.ipAddress != address
                || previousPeer?.status == .unreachable

            var peer = previousPeer ?? Peer(
                id: UUID(),
                name: name,
                hostname: hostname,
                ipAddress: address,
                port: Int(agentPort.rawValue),
                status: .discovered,
                agentVersion: ver,
                lastSeen: Date()
            )

            peer.name = name
            peer.hostname = hostname
            peer.ipAddress = address
            peer.port = Int(agentPort.rawValue)
            if let ver {
                peer.agentVersion = ver
            }
            peer.lastSeen = Date()

            if previousKey != key {
                discoveredPeers.removeValue(forKey: previousKey)
            }
            discoveredPeers[key] = peer

            if previousPeer == nil {
                logger.info("Found peer: \(name) at \(address)")
            } else if previousPeer?.ipAddress != address {
                logger.info("Updated peer address for \(name) to \(address)")
            }

            if shouldProbe {
                scheduleProbe(for: peer)
            }
        }
    }

    // MARK: - Manual add

    func addManualPeer(name: String, ip: String, port: Int = 8477) {
        let peer = Peer.manual(name: name, ip: ip, port: port)
        discoveredPeers[peerKey(for: ip)] = peer

        Task {
            let probed = await probePeer(peer)
            discoveredPeers[peerKey(for: ip)] = probed
        }
    }

    func removePeer(ip: String) {
        discoveredPeers.removeValue(forKey: peerKey(for: ip))
    }

    func updatePeer(_ peer: Peer) {
        let key = existingPeerKey(
            for: peer.hostname,
            ip: normalizedAddress(peer.ipAddress)
        ) ?? peerKey(for: peer.ipAddress)
        discoveredPeers[key] = peer
    }

    /// Runs a bidirectional worker-to-worker benchmark between the local agent
    /// and the selected peer. The stored throughput keeps the slower direction,
    /// which is the useful number when the link is asymmetric.
    func benchmarkPeer(_ peer: Peer) async throws {
        guard let localIP = normalizedAddress(NetworkUtils.localIPAddress) else {
            throw NSError(domain: "DiscoveryService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local IP address is unavailable"])
        }

        benchmarkingPeerIDs.insert(peer.id)
        defer { benchmarkingPeerIDs.remove(peer.id) }

        let localPeer = Peer.manual(name: NetworkUtils.sanitizedComputerName, ip: "127.0.0.1", port: Int(agentPort.rawValue))
        let bytes = 128 * 1024 * 1024

        let forwardSession = UUID().uuidString
        let forwardReceiver = try await client.startBenchmarkReceiver(peer: localPeer, sessionId: forwardSession, maxBytes: bytes)
        let forwardSender = try await client.runBenchmarkSender(
            peer: peer,
            request: BenchSenderRequest(
                sessionId: forwardSession,
                host: localIP,
                port: forwardReceiver.port,
                bytesToSend: bytes,
                chunkSize: 1024 * 1024
            )
        )
        let forwardResult = try await waitForBenchmarkResult(peer: localPeer, sessionId: forwardSession)

        let reverseSession = UUID().uuidString
        let reverseReceiver = try await client.startBenchmarkReceiver(peer: peer, sessionId: reverseSession, maxBytes: bytes)
        let reverseSender = try await client.runBenchmarkSender(
            peer: localPeer,
            request: BenchSenderRequest(
                sessionId: reverseSession,
                host: peer.ipAddress,
                port: reverseReceiver.port,
                bytesToSend: bytes,
                chunkSize: 1024 * 1024
            )
        )
        let reverseResult = try await waitForBenchmarkResult(peer: peer, sessionId: reverseSession)

        var updated = peer
        updated.lastBenchmarkMbps = min(
            forwardResult.throughputMbps ?? forwardSender.throughputMbps,
            reverseResult.throughputMbps ?? reverseSender.throughputMbps
        )
        updated.lastBenchmarkLatencyMs = (forwardSender.connectLatencyMs + reverseSender.connectLatencyMs) / 2
        updatePeer(updated)
    }

    private func waitForBenchmarkResult(peer: Peer, sessionId: String) async throws -> BenchResultResponse {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let result = try await client.fetchBenchmarkResult(peer: peer, sessionId: sessionId)
            switch result.state {
            case .pending:
                try await Task.sleep(for: .milliseconds(250))
            case .completed:
                return result
            case .failed:
                throw NSError(
                    domain: "DiscoveryService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: result.error ?? "benchmark failed"]
                )
            }
        }

        throw NSError(
            domain: "DiscoveryService",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for benchmark result"]
        )
    }
}

// MARK: - TXT record helpers

private extension NWTXTRecord {
    var stringDictionary: [String: String] {
        var result: [String: String] = [:]
        self.forEach { element in
            switch element.value {
            case .string(let str):
                result[element.key.lowercased()] = str
            case .data(let data):
                if let str = String(data: data, encoding: .utf8) {
                    result[element.key.lowercased()] = str
                }
            case .empty:
                result[element.key.lowercased()] = ""
            case .none:
                break
            @unknown default:
                break
            }
        }
        return result
    }
}
