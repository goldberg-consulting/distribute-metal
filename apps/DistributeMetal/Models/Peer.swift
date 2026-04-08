import Foundation

enum PeerStatus: String, Codable {
    case discovered
    case unreachable
    case agentFailed
    case ready
    case busy
}

struct Peer: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var hostname: String
    var ipAddress: String
    var port: Int
    var status: PeerStatus

    var arch: String?
    var chip: String?
    var memoryGB: Int?
    var macOSVersion: String?
    var agentVersion: String?
    var mcclVersion: String?
    var pythonVersion: String?
    var uvAvailable: Bool?
    var freeDiskGB: Double?
    var statusDetail: String?
    var sshUser: String?
    var receiveRoot: String?
    var sshConfigured: Bool = false
    var lastBenchmarkMbps: Double?
    var lastBenchmarkLatencyMs: Double?

    var lastSeen: Date

    var displayAddress: String { "\(ipAddress):\(port)" }
    var statusLabel: String {
        switch status {
        case .discovered:
            return "discovered"
        case .unreachable:
            return "unreachable"
        case .agentFailed:
            return "agent failed"
        case .ready:
            return "ready"
        case .busy:
            return "busy"
        }
    }

    static func manual(name: String, ip: String, port: Int = 8477) -> Peer {
        Peer(
            id: UUID(),
            name: name,
            hostname: "\(name).local",
            ipAddress: ip,
            port: port,
            status: .discovered,
            lastSeen: Date()
        )
    }
}
