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

struct PrepareRequest: Codable {
    var jobId: String
    var spec: JobSpec

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case spec
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
