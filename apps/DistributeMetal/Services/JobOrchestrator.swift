import Foundation
import os.log
import Combine

/// Coordinates the worker lifecycle for a single job.
///
/// The run sequence is: authorize restricted SSH push access, initialize worker
/// workspaces, rsync the staged project and data, prepare/provision, poll until
/// ready, then launch `torchrun` with rank-specific parameters.
@MainActor
final class JobOrchestrator: ObservableObject {
    static let shared = JobOrchestrator()

    private let logger = Logger(subsystem: "one.measured.distribute-metal", category: "Orchestrator")
    private let client = AgentClient()
    private let sshService = SSHService.shared
    private let syncService = RsyncService.shared

    @Published var currentJob: Job?
    @Published var jobHistory: [Job] = []

    private init() {}

    // MARK: - Create job from YAML path

    func createJob(from yamlURL: URL, peers: [Peer]) throws -> Job {
        let data = try Data(contentsOf: yamlURL)
        let decoder = YAMLLiteDecoder()
        let spec = try decoder.decode(data)

        let job = Job(
            name: spec.project.name,
            spec: spec,
            sourcePath: yamlURL.deletingLastPathComponent(),
            peers: peers
        )

        currentJob = job
        logger.info("Created job '\(job.name)' with \(peers.count) peers, world_size=\(job.worldSize)")
        return job
    }

    // MARK: - Run full lifecycle

    func run() async {
        guard var job = currentJob else {
            logger.error("No current job to run")
            return
        }
        guard !job.assignedPeers.isEmpty else {
            logger.error("No peers assigned to job")
            appendLog("Job failed: no peers assigned.")
            return
        }

        do {
            // Phase: initialize sync + prepare all peers
            job.phase = .syncing
            currentJob = job
            appendLog("Initializing secure sync for \(job.assignedPeers.count) peer(s)...")

            let preparedPeers = try await preparePeersForRun(job: job)
            job.assignedPeers = preparedPeers
            job.masterPeer = preparedPeers.first
            currentJob = job

            appendLog("All peers prepared. Waiting for ready state...")

            // Phase: wait for all peers to be ready (provisioned)
            job.phase = .provisioning
            currentJob = job
            try await waitForAllReady(peers: preparedPeers, jobId: job.id.uuidString, timeout: 300)

            // Phase: barriered launch
            job.phase = .launching
            job.startedAt = Date()
            currentJob = job
            appendLog("Launching torchrun across \(job.worldSize) rank(s)...")

            let masterPeer = preparedPeers[0]
            let masterAddr = masterPeer.ipAddress
            let masterPort = job.spec.training.torchrun.masterPort ?? 29500

            try await withThrowingTaskGroup(of: Void.self) { group in
                for (idx, peer) in preparedPeers.enumerated() {
                    let req = LaunchRequest(
                        jobId: job.id.uuidString,
                        masterAddr: masterAddr,
                        masterPort: masterPort,
                        worldSize: job.worldSize,
                        nodeRank: idx,
                        nprocPerNode: job.spec.training.torchrun.nprocPerNode
                    )
                    group.addTask {
                        let resp = try await self.client.launch(peer: peer, request: req)
                        if !resp.ok {
                            throw OrchestratorError.launchFailed(peer: peer.name, message: resp.message ?? "unknown")
                        }
                    }
                }
                try await group.waitForAll()
            }

            job.phase = .running
            currentJob = job
            appendLog("Training running.")

        } catch {
            job.phase = .failed
            job.completedAt = Date()
            currentJob = job
            appendLog("Job failed: \(error.localizedDescription)")
            logger.error("Job failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stop

    func stop() async {
        guard var job = currentJob else { return }
        appendLog("Stopping job...")

        for peer in job.assignedPeers {
            do {
                _ = try await client.stop(peer: peer, jobId: job.id.uuidString)
            } catch {
                logger.warning("Failed to stop on \(peer.name): \(error.localizedDescription)")
            }
        }

        job.phase = .cancelled
        job.completedAt = Date()
        currentJob = job
        appendLog("Job stopped.")
    }

    // MARK: - Clean

    func cleanJob() async {
        guard var job = currentJob else { return }
        appendLog("Cleaning job workspace on all peers...")

        for peer in job.assignedPeers {
            do {
                _ = try await client.clean(peer: peer, jobId: job.id.uuidString)
            } catch {
                logger.warning("Clean failed on \(peer.name): \(error.localizedDescription)")
            }
        }

        job.phase = .cleaned
        currentJob = job
        jobHistory.append(job)
        appendLog("Cleaned.")
    }

    // MARK: - Helpers

    private func preparePeersForRun(job: Job) async throws -> [Peer] {
        let client = self.client
        let sshService = self.sshService
        let syncService = self.syncService

        return try await withThrowingTaskGroup(of: Peer.self) { group in
            for peer in job.assignedPeers {
                group.addTask {
                    let preparedPeer = try await sshService.configurePushAccess(for: peer, client: client)
                    await MainActor.run {
                        DiscoveryService.shared.updatePeer(preparedPeer)
                    }

                    let initResponse = try await client.initializeJob(
                        peer: preparedPeer,
                        jobId: job.id.uuidString,
                        spec: job.spec
                    )
                    if !initResponse.ok {
                        throw OrchestratorError.syncFailed(peer: peer.name, message: initResponse.message ?? "job init failed")
                    }

                    try syncService.sync(job: job, to: preparedPeer)

                    let prepareResponse = try await client.prepare(
                        peer: preparedPeer,
                        jobId: job.id.uuidString
                    )
                    if !prepareResponse.ok {
                        throw OrchestratorError.prepareFailed(peer: peer.name, message: prepareResponse.message ?? "prepare failed")
                    }

                    await MainActor.run {
                        DiscoveryService.shared.updatePeer(preparedPeer)
                    }
                    return preparedPeer
                }
            }

            var preparedPeers: [Peer] = []
            for try await peer in group {
                preparedPeers.append(peer)
            }

            let order = job.assignedPeers.map(\.id)
            return preparedPeers.sorted { left, right in
                order.firstIndex(of: left.id) ?? 0 < order.firstIndex(of: right.id) ?? 0
            }
        }
    }

    private func waitForAllReady(peers: [Peer], jobId: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var allReady = true
            for peer in peers {
                let status = try await client.fetchStatus(from: peer)
                if status.state == .failed {
                    throw OrchestratorError.peerFailed(peer: peer.name)
                }
                if status.state != .ready {
                    allReady = false
                }
            }
            if allReady { return }
            try await Task.sleep(for: .seconds(2))
        }

        throw OrchestratorError.readyTimeout
    }

    private func appendLog(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)"
        currentJob?.logs.append(line)
        logger.info("\(message)")
    }
}

enum OrchestratorError: LocalizedError {
    case syncFailed(peer: String, message: String)
    case prepareFailed(peer: String, message: String)
    case launchFailed(peer: String, message: String)
    case peerFailed(peer: String)
    case readyTimeout

    var errorDescription: String? {
        switch self {
        case .syncFailed(let p, let m): return "Sync failed on \(p): \(m)"
        case .prepareFailed(let p, let m): return "Prepare failed on \(p): \(m)"
        case .launchFailed(let p, let m): return "Launch failed on \(p): \(m)"
        case .peerFailed(let p): return "Peer \(p) entered failed state"
        case .readyTimeout: return "Timed out waiting for all peers to be ready"
        }
    }
}
