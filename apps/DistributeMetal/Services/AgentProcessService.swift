import Foundation
import os.log

@MainActor
final class AgentProcessService: ObservableObject {
    static let shared = AgentProcessService()

    private let logger = Logger(subsystem: "one.measured.distribute-metal", category: "AgentProcess")
    private let port: UInt16 = 8477
    private var process: Process?
    private var stderrPipe: Pipe?

    @Published private(set) var agentRunning = false

    private init() {}

    func start() {
        guard process == nil else { return }

        guard let agentDir = locateAgentDirectory() else {
            logger.warning("Agent source not found in app bundle or working directory")
            return
        }

        guard let (executable, arguments) = buildCommand(agentDir: agentDir) else {
            logger.warning("Neither uv nor python3 found on PATH; agent will not start")
            return
        }

        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = agentDir
        child.standardOutput = FileHandle.nullDevice

        let pipe = Pipe()
        child.standardError = pipe
        stderrPipe = pipe

        forwardStderr(pipe)

        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self else { return }
                if self.process?.processIdentifier == terminated.processIdentifier {
                    self.process = nil
                    self.agentRunning = false
                    self.logger.info("Agent exited with status \(terminated.terminationStatus, privacy: .public)")
                }
            }
        }

        do {
            try child.run()
            process = child
            agentRunning = true
            logger.info("Agent started (pid \(child.processIdentifier, privacy: .public)) from \(agentDir.path, privacy: .public)")
        } catch {
            logger.error("Failed to start agent: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let child = process, child.isRunning else {
            process = nil
            agentRunning = false
            return
        }

        child.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            if child.isRunning {
                kill(child.processIdentifier, SIGKILL)
            }
            Task { @MainActor in
                self?.process = nil
                self?.agentRunning = false
            }
        }

        logger.info("Agent stop requested")
    }

    private func locateAgentDirectory() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("agent"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("pyproject.toml").path) {
            return bundled
        }

        let devFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agent")
        if FileManager.default.fileExists(atPath: devFallback.appendingPathComponent("pyproject.toml").path) {
            return devFallback
        }

        return nil
    }

    private func buildCommand(agentDir: URL) -> (URL, [String])? {
        if let uv = which("uv") {
            return (uv, ["run", "--directory", agentDir.path, "distribute-metal-agent"])
        }
        if let python3 = which("python3") {
            return (python3, [
                "-m", "uvicorn",
                "distribute_metal_agent.server:app",
                "--host", "0.0.0.0",
                "--port", String(port)
            ])
        }
        return nil
    }

    private func which(_ name: String) -> URL? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.local/bin" },
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.cargo/bin" },
        ].compactMap { $0 }

        for dir in searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func forwardStderr(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                self?.logger.info("agent: \(text, privacy: .public)")
            }
        }
    }
}
