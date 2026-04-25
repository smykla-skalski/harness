import ArgumentParser
import Foundation
import HarnessMonitorE2ECore

struct HarnessMonitorE2E: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harness-monitor-e2e",
        abstract: "Compiled helpers for the Harness Monitor agents end-to-end lane.",
        subcommands: [
            AllocatePort.self,
            ResolveCodexLaunch.self,
            ConfigureXctestrun.self,
            BridgeReady.self,
            Prepare.self,
            Teardown.self,
            StartRecording.self,
            StopRecording.self,
            SeedSessionState.self,
            ProbeRuntimes.self,
            InjectHeuristic.self,
            SwarmFullFlow.self,
            SwarmActDriver.self,
        ]
    )
}

struct AllocatePort: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allocate-port",
        abstract: "Print a free TCP port on 127.0.0.1."
    )

    func run() throws {
        let port = try PortAllocator.allocateLocalTCPPort()
        print(port)
    }
}

struct ResolveCodexLaunch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve-codex-launch",
        abstract: "Resolve a supported codex model + effort by inspecting `codex debug models`. Prints '<slug>\\n<effort>' or nothing when no model qualifies."
    )

    @Option(name: .long, help: "Path to the codex binary.")
    var codexBinary: String

    func run() throws {
        let stdout = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexBinary)
        process.arguments = ["debug", "models"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            // Mirror the python helper: silently exit 0 when codex is not invokable.
            return
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let resolution = CodexLaunchResolver.resolve(fromJSON: data) else { return }
        print(resolution.slug)
        print(resolution.effort)
    }
}

struct ConfigureXctestrun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure-xctestrun",
        abstract: "Inject env vars into a generated .xctestrun and write the configured copy. Pass --set KEY=VALUE per env var; blank values are skipped."
    )

    @Option(name: .long, help: "Source .xctestrun produced by build-for-testing.")
    var source: String
    @Option(name: .long, help: "Destination .configured.xctestrun path.")
    var destination: String
    @Option(name: .long, help: "Target dictionary key inside the xctestrun.")
    var target: String = XctestrunConfigurator.agentsTargetKey
    @Option(name: .long, parsing: .singleValue,
            help: "Repeatable KEY=VALUE pair injected into both env dictionaries; ignored when VALUE is empty.")
    var set: [String] = []

    func run() throws {
        var updates: [String: String] = [:]
        for entry in set {
            guard let separator = entry.firstIndex(of: "=") else {
                throw ValidationError("--set expected KEY=VALUE; got '\(entry)'")
            }
            let key = String(entry[..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard !key.isEmpty else {
                throw ValidationError("--set KEY must not be empty")
            }
            if value.isEmpty { continue }
            updates[key] = value
        }
        try XctestrunConfigurator.configure(
            source: URL(fileURLWithPath: source),
            destination: URL(fileURLWithPath: destination),
            targetKey: target,
            updates: updates
        )
    }
}

struct BridgeReady: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridge-ready",
        abstract: "Read `harness bridge status --json` from stdin; exit 0 when the bridge reports running with required capabilities healthy."
    )

    func run() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if !BridgeReadiness.isReady(fromJSON: data) {
            throw ExitCode(1)
        }
    }
}

struct Prepare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Spawn daemon + bridge, create both Agents e2e sessions, and emit the resulting manifest JSON."
    )

    @Option(name: .long) var stateRoot: String
    @Option(name: .long) var dataRoot: String
    @Option(name: .long) var dataHome: String
    @Option(name: .long) var daemonLog: String
    @Option(name: .long) var bridgeLog: String
    @Option(name: .long) var harnessBinary: String
    @Option(name: .long) var codexBinary: String
    @Option(name: .long) var projectDir: String
    @Option(name: .long) var terminalSessionId: String
    @Option(name: .long) var codexSessionId: String
    @Option(name: .long, help: "Optional fixed codex port; disables retry-on-conflict.") var codexPort: UInt16?
    @Option(name: .long, help: "Optional path to write manifest JSON. Defaults to stdout.") var manifestOutput: String?

    func run() throws {
        let inputs = PrepareInputs(
            stateRoot: URL(fileURLWithPath: stateRoot, isDirectory: true),
            dataRoot: URL(fileURLWithPath: dataRoot, isDirectory: true),
            dataHome: URL(fileURLWithPath: dataHome, isDirectory: true),
            daemonLog: URL(fileURLWithPath: daemonLog),
            bridgeLog: URL(fileURLWithPath: bridgeLog),
            harnessBinary: URL(fileURLWithPath: harnessBinary),
            codexBinary: URL(fileURLWithPath: codexBinary),
            projectDir: URL(fileURLWithPath: projectDir, isDirectory: true),
            terminalSessionID: terminalSessionId,
            codexSessionID: codexSessionId,
            codexPortOverride: codexPort
        )

        let manifest = try PrepareOrchestrator.run(inputs)
        let payload = try manifest.encoded()
        if let manifestOutput {
            try payload.write(to: URL(fileURLWithPath: manifestOutput), options: .atomic)
        } else {
            FileHandle.standardOutput.write(payload)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

struct Teardown: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teardown",
        abstract: "Read a prepare manifest, terminate daemon + bridge process trees, and remove state unless --keep-state is set."
    )

    @Option(name: .long) var manifest: String
    @Flag(name: .long) var keepState = false

    func run() throws {
        try TeardownOrchestrator.run(
            manifestPath: URL(fileURLWithPath: manifest),
            keepState: keepState
        )
    }
}

struct StartRecording: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start-recording",
        abstract: "Start native screen recording for monitor e2e and keep running until signaled to stop."
    )

    @Option(name: .long, help: "Output .mov path.")
    var output: String
    @Option(name: .long, help: "Log file path.")
    var log: String
    @Option(name: .long, help: "Manifest JSON path written after recording is active.")
    var manifest: String
    @Option(
        name: .long,
        help: "Optional control dir. When set, wait for start.request, write start.ready once recording begins, and stop after stop.request."
    )
    var controlDir: String?

    func run() throws {
        guard #available(macOS 15.0, *) else {
            throw ValidationError("start-recording requires macOS 15 or newer")
        }
        try ScreenRecorder.run(
            outputURL: URL(fileURLWithPath: output),
            logURL: URL(fileURLWithPath: log),
            manifestURL: URL(fileURLWithPath: manifest),
            controlDirectoryURL: controlDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }
}

struct StopRecording: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop-recording",
        abstract: "Stop a native screen recording started by start-recording."
    )

    @Option(name: .long, help: "Manifest JSON path emitted by start-recording.")
    var manifest: String

    func run() throws {
        let manifestURL = URL(fileURLWithPath: manifest)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return
        }
        let recordingManifest = try ScreenRecordingManifest.load(from: manifestURL)
        ScreenRecordingStopper.stop(manifest: recordingManifest)
        try? FileManager.default.removeItem(at: manifestURL)
    }
}

struct InjectHeuristic: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inject-heuristic",
        abstract: "Append a deterministic heuristic-trigger fixture to a runtime raw.jsonl. Prints {\"code\": ..., \"log_path\": ...}."
    )

    @Option(name: .long, help: "Heuristic code (matches src/observe/classifier).")
    var code: String
    @Option(name: .long, help: "Path to the runtime raw.jsonl log to append into.")
    var logPath: String?
    @Option(name: .long, help: "Agent ID whose runtime log should receive the heuristic fixture.")
    var agent: String?
    @Option(name: .long, help: "Swarm session ID used to resolve runtime data when --runtime is omitted.")
    var sessionID: String?
    @Option(name: .long, help: "Project directory for harness status lookups.")
    var projectDir: String?
    @Option(name: .long, help: "Optional runtime override.")
    var runtime: String?
    @Option(name: .long, help: "Optional runtime session ID override.")
    var runtimeSessionID: String?
    @Option(name: .long, help: "Data home root for the swarm session.")
    var dataHome: String?
    @Option(name: .long, help: "Optional harness binary path used when runtime lookup requires session status.")
    var harnessBinary: String?

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let output = try SwarmHeuristicInjection.append(.init(
            code: code,
            logPath: logPath.map { URL(fileURLWithPath: $0) },
            agentID: agent,
            sessionID: sessionID ?? environment["HARNESS_E2E_SESSION_ID"],
            projectDir: (projectDir ?? environment["HARNESS_E2E_PROJECT_DIR"])
                .map { URL(fileURLWithPath: $0, isDirectory: true) },
            runtime: runtime,
            runtimeSessionID: runtimeSessionID,
            dataHome: (dataHome ?? environment["HARNESS_E2E_DATA_HOME"] ?? environment["XDG_DATA_HOME"])
                .map { URL(fileURLWithPath: $0, isDirectory: true) },
            harnessBinary: (harnessBinary ?? environment["HARNESS_E2E_HARNESS_BINARY"])
                .map { URL(fileURLWithPath: $0) }
        ))
        let data = try SwarmHeuristicInjection.encoded(output)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct SeedSessionState: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed-session-state",
        abstract: "Pre-seed the swarm data home with the expected e2e directories."
    )

    @Option(name: .long, help: "Data home root to seed.")
    var dataHome: String?
    @Option(name: .long, help: "Optional agent ID that should receive a stall ledger marker.")
    var agent: String = ""
    @Option(name: .long, help: "Optional stall duration written into the ledger marker.")
    var stallSeconds: Int?

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let resolvedDataHome = dataHome
            ?? environment["HARNESS_E2E_DATA_HOME"]
            ?? environment["XDG_DATA_HOME"]
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("harness-swarm-e2e-data", isDirectory: true).path
        let output = try SwarmSeedState.seed(
            dataHome: URL(fileURLWithPath: resolvedDataHome, isDirectory: true),
            stalledAgentID: agent.isEmpty ? nil : agent,
            stallSeconds: stallSeconds
        )
        let data = try SwarmSeedState.encoded(output)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct ProbeRuntimes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe-runtimes",
        abstract: "Probe local AI runtime availability and emit JSON."
    )

    func run() throws {
        let report = SwarmRuntimeProbe().run()
        let data = try SwarmRuntimeProbe.encoded(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct SwarmFullFlow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swarm-full-flow",
        abstract: "Run the real-runtime swarm full-flow e2e lane through the Swift helper."
    )

    @Flag(name: .long, help: "Verify the final session state after the UI run finishes.")
    var assert = false

    func run() throws {
        let status = try SwarmFullFlowOrchestrator.run(assertMode: assert)
        guard status == 0 else {
            throw ExitCode(status)
        }
    }
}

struct SwarmActDriver: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swarm-act-driver",
        abstract: "Internal helper that drives the swarm act markers for swarm-full-flow."
    )

    @Option(name: .long) var repoRoot: String
    @Option(name: .long) var stateRoot: String
    @Option(name: .long) var dataHome: String
    @Option(name: .long) var projectDir: String
    @Option(name: .long) var syncDir: String
    @Option(name: .long) var sessionID: String
    @Option(name: .long) var harnessBinary: String
    @Option(name: .long) var probeJSON: String

    func run() throws {
        try SwarmFullFlowOrchestrator.runActDriver(.init(
            repoRoot: URL(fileURLWithPath: repoRoot, isDirectory: true),
            stateRoot: URL(fileURLWithPath: stateRoot, isDirectory: true),
            dataHome: URL(fileURLWithPath: dataHome, isDirectory: true),
            projectDir: URL(fileURLWithPath: projectDir, isDirectory: true),
            syncDir: URL(fileURLWithPath: syncDir, isDirectory: true),
            sessionID: sessionID,
            harnessBinary: URL(fileURLWithPath: harnessBinary),
            probeJSON: URL(fileURLWithPath: probeJSON)
        ))
    }
}

HarnessMonitorE2E.main()
