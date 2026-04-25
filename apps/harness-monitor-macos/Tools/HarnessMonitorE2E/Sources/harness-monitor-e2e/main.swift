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

HarnessMonitorE2E.main()
