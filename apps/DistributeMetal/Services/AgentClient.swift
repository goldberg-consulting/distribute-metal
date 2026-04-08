import Foundation
import os.log

enum AgentClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The agent returned an invalid response."
        case .httpStatus(let code, let body):
            if body.isEmpty {
                return "The agent returned HTTP \(code)."
            }
            return "The agent returned HTTP \(code): \(body)"
        }
    }
}

/// Thin HTTP client for the worker agent API.
///
/// The bearer token is read from the same environment variable or token file as
/// the menu bar app and MCP integration, so the control plane stays aligned.
actor AgentClient {
    private let logger = Logger(subsystem: "one.measured.distribute-metal", category: "AgentClient")
    private let session: URLSession
    private let timeout: TimeInterval = 30
    private let token: String?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.token = Self.loadToken()
    }

    private func url(for peer: Peer, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = peer.ipAddress
        components.port = peer.port

        guard let baseURL = components.url,
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            preconditionFailure("Invalid peer address: \(peer.ipAddress):\(peer.port)")
        }

        return url
    }

    private static func loadToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["DISTRIBUTE_METAL_TOKEN"], !env.isEmpty {
            return env
        }
        let tokenFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/distribute-metal/token")
        if let data = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let line = data.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            if !line.isEmpty { return line }
        }
        return nil
    }

    // MARK: - Status

    func fetchStatus(from peer: Peer) async throws -> AgentStatusResponse {
        try await request(peer: peer, path: "/status", method: "GET")
    }

    // MARK: - Job init

    func initializeJob(peer: Peer, jobId: String, spec: JobSpec) async throws -> AgentResponse {
        let req = JobInitRequest(jobId: jobId, spec: spec)
        return try await request(peer: peer, path: "/jobs/init", method: "POST", body: req)
    }

    // MARK: - Prepare (send job spec, trigger bundle sync + venv provision)

    func prepare(peer: Peer, jobId: String) async throws -> AgentResponse {
        let req = PrepareRequest(jobId: jobId)
        return try await request(peer: peer, path: "/jobs/prepare", method: "POST", body: req)
    }

    // MARK: - Launch (start torchrun with assigned rank)

    func launch(peer: Peer, request: LaunchRequest) async throws -> AgentResponse {
        try await self.request(peer: peer, path: "/jobs/launch", method: "POST", body: request)
    }

    // MARK: - Stop

    func stop(peer: Peer, jobId: String) async throws -> AgentResponse {
        let body = ["job_id": jobId]
        return try await request(peer: peer, path: "/jobs/stop", method: "POST", body: body)
    }

    // MARK: - Clean

    func clean(peer: Peer, jobId: String) async throws -> AgentResponse {
        let body = ["job_id": jobId]
        return try await request(peer: peer, path: "/jobs/clean", method: "POST", body: body)
    }

    // MARK: - Logs

    func fetchLogs(from peer: Peer, jobId: String, tail: Int = 200) async throws -> [String] {
        try await request(peer: peer, path: "/jobs/\(jobId)/logs?tail=\(tail)", method: "GET")
    }

    // MARK: - SSH sync setup

    func authorizeSSH(peer: Peer, publicKey: String, keyName: String) async throws -> SSHAuthorizeResponse {
        let req = SSHAuthorizeRequest(publicKey: publicKey, keyName: keyName)
        return try await request(peer: peer, path: "/ssh/authorize", method: "POST", body: req)
    }

    // MARK: - Benchmarks

    func startBenchmarkReceiver(peer: Peer, sessionId: String, maxBytes: Int) async throws -> BenchReceiverResponse {
        let req = BenchReceiverRequest(sessionId: sessionId, maxBytes: maxBytes)
        return try await request(peer: peer, path: "/diag/bench/receiver", method: "POST", body: req)
    }

    func runBenchmarkSender(peer: Peer, request: BenchSenderRequest) async throws -> BenchSenderResponse {
        try await self.request(peer: peer, path: "/diag/bench/sender", method: "POST", body: request)
    }

    func fetchBenchmarkResult(peer: Peer, sessionId: String) async throws -> BenchResultResponse {
        try await request(peer: peer, path: "/diag/bench/\(sessionId)", method: "GET")
    }

    // MARK: - Upload bundle archive

    func uploadBundle(to peer: Peer, jobId: String, archiveURL: URL) async throws -> AgentResponse {
        var urlRequest = URLRequest(url: url(for: peer, path: "/jobs/\(jobId)/bundle"))
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.upload(for: urlRequest, fromFile: archiveURL)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AgentResponse.self, from: data)
    }

    // MARK: - Helpers

    private func request<Response: Decodable>(
        peer: Peer,
        path: String,
        method: String
    ) async throws -> Response {
        var urlRequest = URLRequest(url: url(for: peer, path: path))
        urlRequest.httpMethod = method
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func request<RequestBody: Encodable, Response: Decodable>(
        peer: Peer,
        path: String,
        method: String,
        body: RequestBody
    ) async throws -> Response {
        var urlRequest = URLRequest(url: url(for: peer, path: path))
        urlRequest.httpMethod = method
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Agent request failed with HTTP \(http.statusCode, privacy: .public)")
            throw AgentClientError.httpStatus(http.statusCode, body)
        }
    }
}
