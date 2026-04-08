import Foundation
import os.log

enum SSHServiceError: LocalizedError {
    case missingPublicKey(URL)
    case rsyncUnavailable
    case sshKeyscanFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPublicKey(let url):
            return "Missing SSH public key at \(url.path)"
        case .rsyncUnavailable:
            return "The worker does not have rsync available for push sync."
        case .sshKeyscanFailed(let message):
            return "Failed to trust the worker SSH host key: \(message)"
        }
    }
}

/// Manages per-worker SSH identities for coordinator-driven push sync.
///
/// Each worker receives its own keypair and known-host entry so a compromised
/// relationship can be rotated without affecting every other worker.
final class SSHService {
    static let shared = SSHService()

    private let logger = Logger(subsystem: "one.measured.distribute-metal", category: "SSHService")
    private let fileManager = FileManager.default

    private init() {}

    func configurePushAccess(for peer: Peer, client: AgentClient) async throws -> Peer {
        let privateKeyURL = try ensureKeyPair(for: peer)
        let publicKeyURL = privateKeyURL.appendingPathExtension("pub")
        guard fileManager.fileExists(atPath: publicKeyURL.path) else {
            throw SSHServiceError.missingPublicKey(publicKeyURL)
        }

        let publicKey = try String(contentsOf: publicKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let keyName = "distribute-metal-\(sanitizedName(for: peer))"
        let response = try await client.authorizeSSH(peer: peer, publicKey: publicKey, keyName: keyName)
        guard response.rsyncAvailable else {
            throw SSHServiceError.rsyncUnavailable
        }

        try trust(peer: peer, hostKeys: response.hostKeys)

        var updated = peer
        updated.sshUser = response.sshUser
        updated.receiveRoot = response.receiveRoot
        updated.sshConfigured = true
        logger.info("Configured SSH push access for \(peer.name, privacy: .public)")
        return updated
    }

    func privateKeyURL(for peer: Peer) throws -> URL {
        try ensureKeyPair(for: peer)
    }

    func knownHostsURL() throws -> URL {
        try ensureBaseDirectories()
        let url = baseDirectory.appendingPathComponent("known_hosts")
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }

    private var baseDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/distribute-metal/ssh", isDirectory: true)
    }

    private func ensureBaseDirectories() throws {
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func ensureKeyPair(for peer: Peer) throws -> URL {
        try ensureBaseDirectories()
        let keyURL = baseDirectory.appendingPathComponent(sanitizedName(for: peer), isDirectory: false)
        let publicKeyURL = keyURL.appendingPathExtension("pub")

        if fileManager.fileExists(atPath: keyURL.path), fileManager.fileExists(atPath: publicKeyURL.path) {
            return keyURL
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-q",
            "-t", "ed25519",
            "-N", "",
            "-C", "distribute-metal:\(peer.hostname)",
            "-f", keyURL.path
        ]
        try run(process)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyURL.path)
        return keyURL
    }

    private func trust(peer: Peer, hostKeys: [String]) throws {
        let knownHosts = try knownHostsURL()
        var existing = ""
        if fileManager.fileExists(atPath: knownHosts.path) {
            existing = try String(contentsOf: knownHosts, encoding: .utf8)
        }

        let keysToWrite = hostKeys.isEmpty ? try scannedHostKeys(for: peer.ipAddress) : hostKeys
        let hostAliases = Set([peer.ipAddress, peer.hostname]).filter { !$0.isEmpty }
        let lines = hostAliases.flatMap { host in
            keysToWrite.map { "\(host) \($0)" }
        }

        let missing = lines.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return }

        let handle = try FileHandle(forWritingTo: knownHosts)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for line in missing {
            if !existing.isEmpty, !existing.hasSuffix("\n") {
                try handle.write(contentsOf: Data("\n".utf8))
                existing.append("\n")
            }
            try handle.write(contentsOf: Data("\(line)\n".utf8))
            existing.append("\(line)\n")
        }
    }

    private func scannedHostKeys(for host: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        process.arguments = ["-T", "5", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try run(process)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = output
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return parts[1]
            }
        guard !lines.isEmpty else {
            throw SSHServiceError.sshKeyscanFailed("No host keys returned for \(host)")
        }
        return lines
    }

    private func run(_ process: Process) throws {
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown SSH error"
            throw SSHServiceError.sshKeyscanFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func sanitizedName(for peer: Peer) -> String {
        peer.hostname
            .lowercased()
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
    }
}
