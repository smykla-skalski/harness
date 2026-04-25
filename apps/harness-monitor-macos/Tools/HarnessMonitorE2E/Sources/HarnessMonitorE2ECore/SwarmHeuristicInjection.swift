import Foundation

public enum SwarmHeuristicInjection {
    public enum Failure: Error, CustomStringConvertible {
        case missingLogPath
        case missingSessionID
        case missingHarnessBinary
        case sessionStatusLookupFailed(String)
        case agentNotFound(String)
        case runtimeUnresolved(String)

        public var description: String {
            switch self {
            case .missingLogPath:
                return "inject-heuristic requires --log-path or enough session context to resolve it"
            case .missingSessionID:
                return "runtime lookup requires --session-id when --runtime is omitted"
            case .missingHarnessBinary:
                return "runtime lookup requires HARNESS_E2E_HARNESS_BINARY or --harness-binary"
            case .sessionStatusLookupFailed(let stderr):
                return "failed to resolve agent runtime from session status: \(stderr)"
            case .agentNotFound(let agentID):
                return "failed to resolve agent \(agentID) from session status"
            case .runtimeUnresolved(let agentID):
                return "failed to resolve runtime session for agent \(agentID)"
            }
        }
    }

    public struct Inputs {
        public let code: String
        public let logPath: URL?
        public let agentID: String?
        public let sessionID: String?
        public let projectDir: URL?
        public let runtime: String?
        public let runtimeSessionID: String?
        public let dataHome: URL?
        public let harnessBinary: URL?

        public init(
            code: String,
            logPath: URL? = nil,
            agentID: String? = nil,
            sessionID: String? = nil,
            projectDir: URL? = nil,
            runtime: String? = nil,
            runtimeSessionID: String? = nil,
            dataHome: URL? = nil,
            harnessBinary: URL? = nil
        ) {
            self.code = code
            self.logPath = logPath
            self.agentID = agentID
            self.sessionID = sessionID
            self.projectDir = projectDir
            self.runtime = runtime
            self.runtimeSessionID = runtimeSessionID
            self.dataHome = dataHome
            self.harnessBinary = harnessBinary
        }
    }

    public struct Output: Codable {
        public let code: String
        public let logPath: String

        enum CodingKeys: String, CodingKey {
            case code
            case logPath = "log_path"
        }
    }

    public static func append(_ inputs: Inputs) throws -> Output {
        let logPath = try resolveLogPath(inputs)
        try HeuristicFixtures.append(code: inputs.code, to: logPath)
        return Output(code: inputs.code, logPath: logPath.path)
    }

    public static func encoded(_ output: Output) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(output)
    }

    private static func resolveLogPath(_ inputs: Inputs) throws -> URL {
        if let logPath = inputs.logPath {
            return logPath
        }

        guard
            let dataHome = inputs.dataHome,
            let agentID = inputs.agentID,
            dataHome.path.isEmpty == false
        else {
            throw Failure.missingLogPath
        }

        var runtime = inputs.runtime
        var runtimeSessionID = inputs.runtimeSessionID

        if runtime == nil || runtimeSessionID == nil {
            guard let sessionID = inputs.sessionID else {
                throw Failure.missingSessionID
            }
            guard let harnessBinary = inputs.harnessBinary else {
                throw Failure.missingHarnessBinary
            }
            let projectDir = inputs.projectDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let client = HarnessClient(binary: harnessBinary, dataHome: dataHome)
            let result = client.run([
                "session", "status", sessionID,
                "--json",
                "--project-dir", projectDir.path,
            ])
            guard result.exitStatus == 0 else {
                let stderr = String(data: result.stderr, encoding: .utf8) ?? "<binary>"
                throw Failure.sessionStatusLookupFailed(stderr)
            }
            // Match the prior shell contract: pick the agent object by `.agent_id`.
            let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
            let agents = json?["agents"] as? [[String: Any]] ?? []
            guard let agent = agents.last(where: { ($0["agent_id"] as? String) == agentID }) else {
                throw Failure.agentNotFound(agentID)
            }
            runtime = runtime ?? (agent["runtime"] as? String)
            if runtimeSessionID == nil || runtimeSessionID == "null" {
                runtimeSessionID = agent["agent_session_id"] as? String ?? sessionID
            }
        }

        guard
            let runtime,
            runtime.isEmpty == false,
            let runtimeSessionID,
            runtimeSessionID.isEmpty == false
        else {
            throw Failure.runtimeUnresolved(agentID)
        }

        let projectDir = inputs.projectDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let contextRoot = SwarmRunLayout.projectContextRoot(projectDir: projectDir, dataHome: dataHome)
        return contextRoot
            .appendingPathComponent("agents/sessions/\(runtime)/\(runtimeSessionID)", isDirectory: true)
            .appendingPathComponent("raw.jsonl")
    }
}
