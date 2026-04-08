import Foundation

enum AgentState: String, Codable {
    case idle
    case syncing
    case provisioning
    case ready
    case launching
    case running
    case failed
    case cleaned
}

struct AgentStatusResponse: Codable {
    var state: AgentState
    var jobId: String?
    var arch: String
    var chip: String
    var memoryGB: Int
    var macOSVersion: String
    var agentVersion: String
    var mcclVersion: String?
    var pythonVersion: String?
    var uvAvailable: Bool
    var freeDiskGB: Double

    enum CodingKeys: String, CodingKey {
        case state, arch, chip
        case jobId = "job_id"
        case memoryGB = "memory_gb"
        case macOSVersion = "macos_version"
        case agentVersion = "agent_version"
        case mcclVersion = "mccl_version"
        case pythonVersion = "python_version"
        case uvAvailable = "uv_available"
        case freeDiskGB = "free_disk_gb"
    }
}

struct JobInitRequest: Codable {
    var jobId: String
    var spec: JobSpec

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case spec
    }
}

struct PrepareRequest: Codable {
    var jobId: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
    }
}

struct LaunchRequest: Codable {
    var jobId: String
    var masterAddr: String
    var masterPort: Int
    var worldSize: Int
    var nodeRank: Int
    var nprocPerNode: Int

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case masterAddr = "master_addr"
        case masterPort = "master_port"
        case worldSize = "world_size"
        case nodeRank = "node_rank"
        case nprocPerNode = "nproc_per_node"
    }
}

struct AgentResponse: Codable {
    var ok: Bool
    var message: String?
    var state: AgentState?
}

struct SSHAuthorizeRequest: Codable {
    var publicKey: String
    var keyName: String?

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case keyName = "key_name"
    }
}

struct SSHAuthorizeResponse: Codable {
    var ok: Bool
    var message: String?
    var sshUser: String
    var hostKeys: [String]
    var receiveRoot: String
    var rsyncAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case ok, message
        case sshUser = "ssh_user"
        case hostKeys = "host_keys"
        case receiveRoot = "receive_root"
        case rsyncAvailable = "rsync_available"
    }
}

struct BenchReceiverRequest: Codable {
    var sessionId: String
    var maxBytes: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case maxBytes = "max_bytes"
    }
}

struct BenchReceiverResponse: Codable {
    var sessionId: String
    var port: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case port
    }
}

struct BenchSenderRequest: Codable {
    var sessionId: String
    var host: String
    var port: Int
    var bytesToSend: Int
    var chunkSize: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case host, port
        case bytesToSend = "bytes_to_send"
        case chunkSize = "chunk_size"
    }
}

struct BenchSenderResponse: Codable {
    var sessionId: String
    var bytesSent: Int
    var durationSeconds: Double
    var throughputMbps: Double
    var connectLatencyMs: Double

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case bytesSent = "bytes_sent"
        case durationSeconds = "duration_seconds"
        case throughputMbps = "throughput_mbps"
        case connectLatencyMs = "connect_latency_ms"
    }
}

enum BenchResultState: String, Codable {
    case pending
    case completed
    case failed
}

struct BenchResultResponse: Codable {
    var sessionId: String
    var state: BenchResultState
    var bytesReceived: Int
    var durationSeconds: Double?
    var throughputMbps: Double?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state
        case bytesReceived = "bytes_received"
        case durationSeconds = "duration_seconds"
        case throughputMbps = "throughput_mbps"
        case error
    }
}
