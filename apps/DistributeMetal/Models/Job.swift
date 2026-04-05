import Foundation

enum JobPhase: String, Codable, CaseIterable {
    case draft
    case syncing
    case provisioning
    case ready
    case launching
    case running
    case succeeded
    case failed
    case cancelled
    case cleaning
    case cleaned
}

struct JobSpec: Codable {
    var version: Int
    var project: ProjectSpec
    var python: PythonSpec
    var training: TrainingSpec
    var data: [DataSpec]
    var sync: SyncSpec
    var cleanup: CleanupSpec
    var validation: ValidationSpec

    struct ProjectSpec: Codable {
        var name: String
        var root: String
        var workingDir: String
        var entrypoint: String
        var include: [String]
        var exclude: [String]

        enum CodingKeys: String, CodingKey {
            case name, root, entrypoint, include, exclude
            case workingDir = "working_dir"
        }
    }

    struct PythonSpec: Codable {
        var version: String
        var pyproject: String
        var lockfile: String
    }

    struct TrainingSpec: Codable {
        var backend: String
        var torchrun: TorchrunSpec
        var env: [String: String]?
        var checkpointDir: String?
        var rank0Only: Rank0Only?

        enum CodingKeys: String, CodingKey {
            case backend, torchrun, env
            case checkpointDir = "checkpoint_dir"
            case rank0Only = "rank0_only"
        }

        struct TorchrunSpec: Codable {
            var nprocPerNode: Int
            var masterPort: Int?
            var scriptArgs: [String]?

            enum CodingKeys: String, CodingKey {
                case nprocPerNode = "nproc_per_node"
                case masterPort = "master_port"
                case scriptArgs = "script_args"
            }
        }

        struct Rank0Only: Codable {
            var saveCheckpoints: Bool?
            var writeLogs: Bool?

            enum CodingKeys: String, CodingKey {
                case saveCheckpoints = "save_checkpoints"
                case writeLogs = "write_logs"
            }
        }
    }

    struct DataSpec: Codable {
        var name: String
        var source: String
        var url: String?
        var path: String
        var sha256: String?
        var sizeBytes: Int?
        var unpack: String?

        enum CodingKeys: String, CodingKey {
            case name, source, url, path, sha256, unpack
            case sizeBytes = "size_bytes"
        }
    }

    struct SyncSpec: Codable {
        var mode: String
        var parallelConnections: Int?
        var chunkSizeMb: Int?
        var preferredInterface: String?

        enum CodingKeys: String, CodingKey {
            case mode
            case parallelConnections = "parallel_connections"
            case chunkSizeMb = "chunk_size_mb"
            case preferredInterface = "preferred_interface"
        }
    }

    struct CleanupSpec: Codable {
        var deleteVenvOnSuccess: Bool?
        var deleteSourceOnSuccess: Bool?
        var deleteDataOnSuccess: Bool?
        var retainLogsDays: Int?

        enum CodingKeys: String, CodingKey {
            case deleteVenvOnSuccess = "delete_venv_on_success"
            case deleteSourceOnSuccess = "delete_source_on_success"
            case deleteDataOnSuccess = "delete_data_on_success"
            case retainLogsDays = "retain_logs_days"
        }
    }

    struct ValidationSpec: Codable {
        var requireArm64: Bool?
        var minFreeDiskGb: Int?
        var requiredTools: [String]?
        var checkFirewall: Bool?

        enum CodingKeys: String, CodingKey {
            case requireArm64 = "require_arm64"
            case minFreeDiskGb = "min_free_disk_gb"
            case requiredTools = "required_tools"
            case checkFirewall = "check_firewall"
        }
    }
}

struct Job: Identifiable {
    let id: UUID
    var name: String
    var spec: JobSpec
    var phase: JobPhase
    var sourcePath: URL
    var assignedPeers: [Peer]
    var masterPeer: Peer?
    var worldSize: Int { assignedPeers.count * spec.training.torchrun.nprocPerNode }
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var logs: [String]

    init(name: String, spec: JobSpec, sourcePath: URL, peers: [Peer]) {
        self.id = UUID()
        self.name = name
        self.spec = spec
        self.phase = .draft
        self.sourcePath = sourcePath
        self.assignedPeers = peers
        self.masterPeer = peers.first
        self.createdAt = Date()
        self.logs = []
    }
}
