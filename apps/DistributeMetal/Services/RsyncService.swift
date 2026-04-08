import Foundation
import os.log

enum RsyncServiceError: LocalizedError {
    case sshNotConfigured(String)
    case invalidProjectRoot(String)
    case invalidDataPath(String)
    case missingLocalPath(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .sshNotConfigured(let peer):
            return "SSH push sync is not configured for \(peer)."
        case .invalidProjectRoot(let path):
            return "Invalid project root: \(path)"
        case .invalidDataPath(let path):
            return "Invalid data path in sync spec: \(path)"
        case .missingLocalPath(let path):
            return "Missing local path for sync: \(path)"
        case .commandFailed(let message):
            return message
        }
    }
}

/// Pushes a filtered project snapshot from the coordinator to a worker job
/// workspace over rsync + SSH.
///
/// Filter order matters here: forced secret excludes win first, then user
/// excludes, then include rules, then a final `--exclude=*` closes the tree.
final class RsyncService {
    static let shared = RsyncService()

    private let logger = Logger(subsystem: "one.measured.distribute-metal", category: "RsyncService")
    private let sshService = SSHService.shared
    private let fileManager = FileManager.default
    private let forcedExcludes = [
        ".env",
        ".env.*",
        ".ssh/**",
        "**/.env",
        "**/.env.*",
        "**/*.pem",
        "**/*.key",
        "**/*.p12"
    ]

    private init() {}

    func sync(job: Job, to peer: Peer) throws {
        guard peer.sshConfigured,
              let sshUser = peer.sshUser else {
            throw RsyncServiceError.sshNotConfigured(peer.name)
        }

        let identityURL = try sshService.privateKeyURL(for: peer)
        let knownHostsURL = try sshService.knownHostsURL()
        let projectRoot = try resolvedProjectRoot(for: job)

        try syncProject(
            projectRoot: projectRoot,
            include: job.spec.project.include,
            exclude: job.spec.project.exclude,
            remoteTarget: "\(job.id.uuidString)/incoming/src/",
            sshUser: sshUser,
            peer: peer,
            identityURL: identityURL,
            knownHostsURL: knownHostsURL
        )

        for entry in job.spec.data where shouldPushData(entry) {
            try syncDataEntry(
                entry: entry,
                projectRoot: projectRoot,
                remoteBase: "\(job.id.uuidString)/incoming/data/",
                sshUser: sshUser,
                peer: peer,
                identityURL: identityURL,
                knownHostsURL: knownHostsURL
            )
        }
    }

    private func shouldPushData(_ entry: JobSpec.DataSpec) -> Bool {
        let source = entry.source.lowercased()
        return source == "coordinator" || source == "local"
    }

    private func resolvedProjectRoot(for job: Job) throws -> URL {
        let root = job.sourcePath.appendingPathComponent(job.spec.project.root)
        let standardized = root.standardizedFileURL
        guard standardized.path.hasPrefix(job.sourcePath.standardizedFileURL.path) else {
            throw RsyncServiceError.invalidProjectRoot(job.spec.project.root)
        }
        guard fileManager.fileExists(atPath: standardized.path) else {
            throw RsyncServiceError.missingLocalPath(standardized.path)
        }
        return standardized
    }

    private func syncProject(
        projectRoot: URL,
        include: [String],
        exclude: [String],
        remoteTarget: String,
        sshUser: String,
        peer: Peer,
        identityURL: URL,
        knownHostsURL: URL
    ) throws {
        var arguments = [
            "-a",
            "--delete",
            "--prune-empty-dirs",
            "-e", sshCommand(identityURL: identityURL, knownHostsURL: knownHostsURL)
        ]

        for pattern in forcedExcludes {
            arguments.append("--exclude=\(pattern)")
        }
        for pattern in exclude {
            arguments.append("--exclude=\(pattern)")
        }
        arguments.append("--include=*/")
        for pattern in include {
            arguments.append("--include=\(pattern)")
        }
        arguments.append("--exclude=*")
        arguments.append("./")
        arguments.append("\(sshUser)@\(peer.ipAddress):\(remoteTarget)")

        try run(
            executable: "/usr/bin/rsync",
            arguments: arguments,
            currentDirectoryURL: projectRoot
        )
    }

    private func syncDataEntry(
        entry: JobSpec.DataSpec,
        projectRoot: URL,
        remoteBase: String,
        sshUser: String,
        peer: Peer,
        identityURL: URL,
        knownHostsURL: URL
    ) throws {
        let normalized = try normalizeRelativePath(entry.path)
        let localRoot: URL
        let relativeSource: String
        let useRelative = normalized != "."

        if normalized == "data" || normalized.hasPrefix("data/") {
            localRoot = projectRoot.appendingPathComponent("data", isDirectory: true)
            let suffix = normalized == "data" ? "" : String(normalized.dropFirst("data/".count))
            relativeSource = suffix.isEmpty ? "./" : "./\(suffix)"
        } else {
            localRoot = projectRoot
            relativeSource = "./\(normalized)"
        }

        let resolvedPath = localRoot.appendingPathComponent(relativeSource.replacingOccurrences(of: "./", with: ""))
            .standardizedFileURL
        guard resolvedPath.path.hasPrefix(projectRoot.path) else {
            throw RsyncServiceError.invalidDataPath(entry.path)
        }
        guard fileManager.fileExists(atPath: resolvedPath.path) else {
            throw RsyncServiceError.missingLocalPath(resolvedPath.path)
        }

        var arguments = [
            "-a",
            "--delete",
            "-e", sshCommand(identityURL: identityURL, knownHostsURL: knownHostsURL)
        ]
        if useRelative {
            arguments.append("-R")
        }
        arguments.append(relativeSource)
        arguments.append("\(sshUser)@\(peer.ipAddress):\(remoteBase)")

        try run(
            executable: "/usr/bin/rsync",
            arguments: arguments,
            currentDirectoryURL: localRoot
        )
    }

    private func sshCommand(identityURL: URL, knownHostsURL: URL) -> String {
        [
            "/usr/bin/ssh",
            "-i", shellQuote(identityURL.path),
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(shellQuote(knownHostsURL.path))"
        ].joined(separator: " ")
    }

    private func run(executable: String, arguments: [String], currentDirectoryURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        logger.info("Running \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "unknown rsync error"
            throw RsyncServiceError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func normalizeRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RsyncServiceError.invalidDataPath(path)
        }

        let normalized = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: #"^\./"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if normalized.isEmpty {
            return "data"
        }
        if normalized.hasPrefix("../") || normalized.contains("/../") || normalized == ".." {
            throw RsyncServiceError.invalidDataPath(path)
        }
        return normalized
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
