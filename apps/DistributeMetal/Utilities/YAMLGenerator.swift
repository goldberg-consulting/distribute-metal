import Foundation

enum YAMLGenerator {

    enum Error: LocalizedError {
        case noPyproject(String)
        case noEntrypoint(String)

        var errorDescription: String? {
            switch self {
            case .noPyproject(let path): return "No pyproject.toml found in \(path)"
            case .noEntrypoint(let path): return "No Python entry script found in \(path)"
            }
        }
    }

    static func generate(from projectURL: URL) throws -> String {
        let fm = FileManager.default
        let root = projectURL.path

        guard fm.fileExists(atPath: projectURL.appendingPathComponent("pyproject.toml").path) else {
            throw Error.noPyproject(root)
        }

        let detectedEntrypoint = detectEntrypoint(in: projectURL) ?? "train.py"
        let workingDir = workingDirectory(for: detectedEntrypoint)
        let entrypoint = URL(fileURLWithPath: detectedEntrypoint).lastPathComponent
        let name = projectURL.lastPathComponent
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let hasLockfile = fm.fileExists(atPath: projectURL.appendingPathComponent("uv.lock").path)
        let dataDirs = detectDataDirs(in: projectURL)
        let pythonVersion = readPythonVersion(in: projectURL) ?? ">=3.11"

        var yaml = """
        version: 1

        project:
          name: "\(name)"
          root: "."
          working_dir: "\(workingDir)"
          entrypoint: "\(entrypoint)"
          include:
            - "**/*.py"
            - "pyproject.toml"
        """

        if hasLockfile {
            yaml += "\n    - \"uv.lock\""
        }

        yaml += """

          exclude:
            - ".git/**"
            - ".venv/**"
            - "__pycache__/**"
            - "checkpoints/**"

        python:
          version: "\(pythonVersion)"
          pyproject: "pyproject.toml"
          lockfile: "\(hasLockfile ? "uv.lock" : "")"

        training:
          backend: "mccl"
          torchrun:
            nproc_per_node: 1
            master_port: 29500
        """

        if !dataDirs.isEmpty {
            yaml += "\n\ndata:"
            for dir in dataDirs {
                yaml += """

                  - name: "\(dir)"
                    source: "coordinator"
                    path: "\(dir)"
                """
            }
        } else {
            yaml += "\n\ndata: []"
        }

        yaml += """


        sync:
          mode: "rsync-push"
          parallel_connections: 8
          chunk_size_mb: 64

        cleanup:
          delete_venv_on_success: true
          delete_source_on_success: true
          delete_data_on_success: false
          retain_logs_days: 7

        validation:
          require_arm64: true
          min_free_disk_gb: 10
          required_tools:
            - "uv"
            - "python3"
        """

        return yaml
    }

    private static func detectEntrypoint(in url: URL) -> String? {
        let candidates = ["train.py", "main.py", "run.py", "src/train.py", "src/main.py"]
        let fm = FileManager.default
        for c in candidates {
            if fm.fileExists(atPath: url.appendingPathComponent(c).path) {
                return c
            }
        }

        if let srcDir = try? fm.contentsOfDirectory(atPath: url.appendingPathComponent("src").path) {
            if let py = srcDir.first(where: { $0.hasSuffix(".py") }) {
                return "src/\(py)"
            }
        }

        if let topLevel = try? fm.contentsOfDirectory(atPath: url.path) {
            if let py = topLevel.first(where: { $0.hasSuffix(".py") && !$0.hasPrefix("__") && !$0.hasPrefix("setup") }) {
                return py
            }
        }

        return nil
    }

    private static func workingDirectory(for entrypoint: String) -> String {
        let directory = URL(fileURLWithPath: entrypoint).deletingLastPathComponent().path
        return directory.isEmpty || directory == "/" ? "." : directory
    }

    private static func detectDataDirs(in url: URL) -> [String] {
        let candidates = ["data", "datasets", "dataset"]
        let fm = FileManager.default
        var found: [String] = []
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.appendingPathComponent(c).path, isDirectory: &isDir), isDir.boolValue {
                found.append(c)
            }
        }
        return found
    }

    private static func readPythonVersion(in url: URL) -> String? {
        let pyprojectPath = url.appendingPathComponent("pyproject.toml").path
        guard let content = try? String(contentsOfFile: pyprojectPath, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("requires-python") {
                if let range = trimmed.range(of: "\"") {
                    let after = trimmed[range.upperBound...]
                    if let end = after.range(of: "\"") {
                        return String(after[..<end.lowerBound])
                    }
                }
            }
        }
        return nil
    }
}
