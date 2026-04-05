import Foundation
import Network
import Combine
import os.log

final class DiscoveryService: ObservableObject {
    static let shared = DiscoveryService()

    private let logger = Logger(subsystem: "one.measured.distribute-metal", category: "Discovery")
    private let serviceType = "_distributemetal._tcp"
    private let agentPort: NWEndpoint.Port = 8477

    @Published var discoveredPeers: [String: Peer] = [:]

    private var browser: NWBrowser?
    private var localBrowser: NWBrowser?
    private var advertiser: NWListener?
    private var dnssdProcess: Process?
    private let queue = DispatchQueue(label: "one.measured.distribute-metal.discovery", qos: .userInitiated)

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
        guard browser == nil else { return }

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
                self?.handleBrowseResults(results)
            }

            b.start(queue: queue)

            if domain == "local." {
                localBrowser = b
            } else {
                browser = b
            }
        }
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        localBrowser?.cancel()
        localBrowser = nil
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
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

            DispatchQueue.main.async {
                self.discoveredPeers[ip] = peer
            }

            logger.info("Found peer: \(name) at \(ip)")
        }
    }

    // MARK: - Manual add

    func addManualPeer(name: String, ip: String, port: Int = 8477) {
        let peer = Peer.manual(name: name, ip: ip, port: port)
        DispatchQueue.main.async {
            self.discoveredPeers[ip] = peer
        }
    }

    func removePeer(ip: String) {
        DispatchQueue.main.async {
            self.discoveredPeers.removeValue(forKey: ip)
        }
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
