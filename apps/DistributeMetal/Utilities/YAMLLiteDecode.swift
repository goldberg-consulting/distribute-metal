import Foundation

/// Minimal YAML-to-JobSpec decoder.
///
/// For v1, the coordinator reads distribute-metal.yaml on macOS.
/// Rather than pulling in a full YAML parser as a dependency,
/// this shells out to `python3 -c "import yaml, json; ..."` which
/// is available on every macOS with Xcode CLT.
/// If that fails, falls back to an error asking the user to install PyYAML.
struct YAMLLiteDecoder {

    enum Error: LocalizedError {
        case pythonUnavailable
        case parseError(String)
        case decodingError(String)

        var errorDescription: String? {
            switch self {
            case .pythonUnavailable:
                return "python3 with PyYAML is required to parse distribute-metal.yaml"
            case .parseError(let msg):
                return "YAML parse error: \(msg)"
            case .decodingError(let msg):
                return "Failed to decode job spec: \(msg)"
            }
        }
    }

    func decode(_ yamlData: Data) throws -> JobSpec {
        guard let yamlString = String(data: yamlData, encoding: .utf8) else {
            throw Error.parseError("File is not valid UTF-8")
        }

        let jsonString = try yamlToJSON(yamlString)

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw Error.parseError("JSON conversion produced invalid output")
        }

        do {
            return try JSONDecoder().decode(JobSpec.self, from: jsonData)
        } catch {
            throw Error.decodingError(error.localizedDescription)
        }
    }

    private func yamlToJSON(_ yaml: String) throws -> String {
        let script = """
        import sys, json
        try:
            import yaml
        except ImportError:
            print("__NEEDS_PYYAML__", file=sys.stderr)
            sys.exit(1)
        data = yaml.safe_load(sys.stdin.read())
        json.dump(data, sys.stdout)
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(yaml.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            if errStr.contains("__NEEDS_PYYAML__") {
                throw Error.pythonUnavailable
            }
            throw Error.parseError(errStr)
        }

        guard let json = String(data: outData, encoding: .utf8), !json.isEmpty else {
            throw Error.parseError("Empty output from YAML parser")
        }

        return json
    }
}
