import Foundation

public struct PrepareInputs {
  public let stateRoot: URL
  public let dataRoot: URL
  public let dataHome: URL
  public let daemonLog: URL
  public let bridgeLog: URL
  public let harnessBinary: URL
  public let codexBinary: URL
  public let projectDir: URL
  public let terminalSessionID: String
  public let codexSessionID: String
  public let codexPortOverride: UInt16?

  public init(
    stateRoot: URL, dataRoot: URL, dataHome: URL,
    daemonLog: URL, bridgeLog: URL,
    harnessBinary: URL, codexBinary: URL, projectDir: URL,
    terminalSessionID: String, codexSessionID: String,
    codexPortOverride: UInt16? = nil
  ) {
    self.stateRoot = stateRoot
    self.dataRoot = dataRoot
    self.dataHome = dataHome
    self.daemonLog = daemonLog
    self.bridgeLog = bridgeLog
    self.harnessBinary = harnessBinary
    self.codexBinary = codexBinary
    self.projectDir = projectDir
    self.terminalSessionID = terminalSessionID
    self.codexSessionID = codexSessionID
    self.codexPortOverride = codexPortOverride
  }
}

public enum PrepareOrchestrator {
  public enum Failure: Error, CustomStringConvertible {
    case sessionStartFailed(id: String, stderr: String)
    case codexWorkspaceUnresolved(sessionID: String)

    public var description: String {
      switch self {
      case .sessionStartFailed(let id, let stderr):
        return "harness session start \(id) failed: \(stderr)"
      case .codexWorkspaceUnresolved(let id):
        return "Failed to resolve workspace for session \(id)"
      }
    }
  }

  public static func run(_ inputs: PrepareInputs) throws -> E2EPreparedManifest {
    try FileManager.default.createDirectory(at: inputs.dataHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: inputs.daemonLog.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Truncate the bridge log between attempts so retry markers stay legible.
    FileManager.default.createFile(atPath: inputs.bridgeLog.path, contents: nil)
    try ObservabilityConfig.seed(dataHome: inputs.dataHome)

    let client = HarnessClient(binary: inputs.harnessBinary, dataHome: inputs.dataHome)

    let daemon = try DaemonSpawner.spawn(client: client, logURL: inputs.daemonLog)
    let bridge: BridgeSpawner.Result
    do {
      bridge = try BridgeSpawner.spawn(
        client: client, codexBinary: inputs.codexBinary, logURL: inputs.bridgeLog,
        portOverride: inputs.codexPortOverride
      )
    } catch {
      ProcessCleanup.terminateTree(rootPID: daemon.processIdentifier)
      throw error
    }

    do {
      try startSession(
        client: client,
        id: inputs.terminalSessionID,
        title: "Agents E2E Terminal",
        context: "Run the explicit monitor Agents end-to-end smoke for terminal-backed agents.",
        projectDir: inputs.projectDir
      )
      try startSession(
        client: client,
        id: inputs.codexSessionID,
        title: "Agents E2E Codex",
        context: "Run the explicit monitor Agents end-to-end smoke for Codex threads.",
        projectDir: inputs.projectDir
      )
    } catch {
      ProcessCleanup.terminateTree(rootPID: bridge.process.processIdentifier)
      ProcessCleanup.terminateTree(rootPID: daemon.processIdentifier)
      throw error
    }

    guard
      let codexWorkspace = client.sessionWorkspace(
        sessionID: inputs.codexSessionID, projectDir: inputs.projectDir
      )
    else {
      ProcessCleanup.terminateTree(rootPID: bridge.process.processIdentifier)
      ProcessCleanup.terminateTree(rootPID: daemon.processIdentifier)
      throw Failure.codexWorkspaceUnresolved(sessionID: inputs.codexSessionID)
    }

    return E2EPreparedManifest(
      daemonPID: daemon.processIdentifier,
      bridgePID: bridge.process.processIdentifier,
      stateRoot: inputs.stateRoot.path,
      dataRoot: inputs.dataRoot.path,
      dataHome: inputs.dataHome.path,
      daemonLog: inputs.daemonLog.path,
      bridgeLog: inputs.bridgeLog.path,
      terminalSessionID: inputs.terminalSessionID,
      codexSessionID: inputs.codexSessionID,
      codexWorkspace: codexWorkspace,
      codexPort: bridge.port
    )
  }

  private static func startSession(
    client: HarnessClient,
    id: String,
    title: String,
    context: String,
    projectDir: URL
  ) throws {
    let result = client.startSession(
      sessionID: id, title: title, context: context, projectDir: projectDir)
    guard result.exitStatus == 0 else {
      throw Failure.sessionStartFailed(
        id: id,
        stderr: String(data: result.stderr, encoding: .utf8) ?? "<binary>"
      )
    }
  }
}

public enum TeardownOrchestrator {
  public static func run(manifestPath: URL, keepState: Bool) throws {
    let data = try Data(contentsOf: manifestPath)
    let manifest = try E2EPreparedManifest.decode(from: data)

    ProcessCleanup.terminateTree(rootPID: manifest.bridgePID)
    ProcessCleanup.terminateTree(rootPID: manifest.daemonPID)

    if keepState { return }

    let stateRoot = URL(fileURLWithPath: manifest.stateRoot, isDirectory: true)
    let dataRoot = URL(fileURLWithPath: manifest.dataRoot, isDirectory: true)
    try? FileManager.default.removeItem(at: stateRoot)
    if !manifest.dataRoot.hasPrefix(manifest.stateRoot) {
      try? FileManager.default.removeItem(at: dataRoot)
    }
  }
}
