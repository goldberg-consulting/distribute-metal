import Foundation

enum PeerStatus: String, Codable {
    case discovered
    case paired
    case preflight
    case ready
    case busy
    case offline
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

    var lastSeen: Date

    var displayAddress: String { "\(ipAddress):\(port)" }

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
