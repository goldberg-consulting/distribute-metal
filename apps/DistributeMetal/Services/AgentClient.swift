import Foundation
import os.log

actor AgentClient {
    private let logger = Logger(subsystem: "com.measured.distribute-metal", category: "AgentClient")
    private let session: URLSession
    private let timeout: TimeInterval = 30

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    private func url(for peer: Peer, path: String) -> URL {
        URL(string: "http://\(peer.ipAddress):\(peer.port)\(path)")!
    }

    // MARK: - Status

    func fetchStatus(from peer: Peer) async throws -> AgentStatusResponse {
        let (data, _) = try await session.data(from: url(for: peer, path: "/status"))
        return try JSONDecoder().decode(AgentStatusResponse.self, from: data)
    }

    // MARK: - Prepare (send job spec, trigger bundle sync + venv provision)

    func prepare(peer: Peer, jobId: String, spec: JobSpec) async throws -> AgentResponse {
        let req = PrepareRequest(jobId: jobId, spec: spec)
        return try await post(peer: peer, path: "/jobs/prepare", body: req)
    }

    // MARK: - Launch (start torchrun with assigned rank)

    func launch(peer: Peer, request: LaunchRequest) async throws -> AgentResponse {
        return try await post(peer: peer, path: "/jobs/launch", body: request)
    }

    // MARK: - Stop

    func stop(peer: Peer, jobId: String) async throws -> AgentResponse {
        let body = ["job_id": jobId]
        return try await post(peer: peer, path: "/jobs/stop", body: body)
    }

    // MARK: - Clean

    func clean(peer: Peer, jobId: String) async throws -> AgentResponse {
        let body = ["job_id": jobId]
        return try await post(peer: peer, path: "/jobs/clean", body: body)
    }

    // MARK: - Logs

    func fetchLogs(from peer: Peer, jobId: String, tail: Int = 200) async throws -> [String] {
        let (data, _) = try await session.data(
            from: url(for: peer, path: "/jobs/\(jobId)/logs?tail=\(tail)")
        )
        return try JSONDecoder().decode([String].self, from: data)
    }

    // MARK: - Upload bundle archive

    func uploadBundle(to peer: Peer, jobId: String, archiveURL: URL) async throws -> AgentResponse {
        var request = URLRequest(url: url(for: peer, path: "/jobs/\(jobId)/bundle"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await session.upload(for: request, fromFile: archiveURL)
        return try JSONDecoder().decode(AgentResponse.self, from: data)
    }

    // MARK: - Helpers

    private func post<T: Encodable>(peer: Peer, path: String, body: T) async throws -> AgentResponse {
        var request = URLRequest(url: url(for: peer, path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(AgentResponse.self, from: data)
    }
}
