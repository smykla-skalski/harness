import Darwin
import Foundation

public struct SwarmActDriverInputs: Sendable {
  public let repoRoot: URL
  public let stateRoot: URL
  public let dataHome: URL
  public let projectDir: URL
  public let syncDir: URL
  public let sessionID: String
  public let harnessBinary: URL
  public let probeJSON: URL
  public let stepTimeoutOverrides: [String: TimeInterval]
  public let progressLog: URL?

  public init(
    repoRoot: URL,
    stateRoot: URL,
    dataHome: URL,
    projectDir: URL,
    syncDir: URL,
    sessionID: String,
    harnessBinary: URL,
    probeJSON: URL,
    stepTimeoutOverrides: [String: TimeInterval] = [:],
    progressLog: URL? = nil
  ) {
    self.repoRoot = repoRoot
    self.stateRoot = stateRoot
    self.dataHome = dataHome
    self.projectDir = projectDir
    self.syncDir = syncDir
    self.sessionID = sessionID
    self.harnessBinary = harnessBinary
    self.probeJSON = probeJSON
    self.stepTimeoutOverrides = stepTimeoutOverrides
    self.progressLog = progressLog
  }
}

public enum SwarmFullFlowOrchestrator {
  public static func run(
    assertMode: Bool,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: URL = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) throws -> Int32 {
    try SwarmFullFlowRunner(
      assertMode: assertMode,
      environment: environment,
      currentDirectory: currentDirectory
    ).run()
  }

  public static func runActDriver(_ inputs: SwarmActDriverInputs) throws {
    try SwarmActDriverRunner(inputs: inputs).run()
  }
}

private enum SwarmContractCommands {
  // Keep the user-facing CLI spellings explicit for the architecture contract.
  static let taskArbitrate = "session task arbitrate"
  static let observeDoctorJSON = "observe doctor --json"
}

private final class SwarmFullFlowRunner {
  private struct CommandResult {
    let exitStatus: Int32
    let stdout: Data
    let stderr: Data
  }

  private struct CommandFailure: Error, CustomStringConvertible {
    let status: Int32
    let message: String

    var description: String { message }
  }

  private let assertMode: Bool
  private let environment: [String: String]
  private let repoRoot: URL
  private let projectDir: URL
  private let commonRepoRoot: URL
  private let appRoot: URL
  private let layout: SwarmRunLayout
  private let destination: String
  private let onlyTesting: String
  private let keepData: Bool
  private let harnessBinary: URL
  private let helperBinary: URL
  private let client: HarnessClient
  private let startedAt: Date
  private var daemonProcess: Process?
  private var actDriverProcess: Process?
  private var screenRecordingProcess: Process?

  init(assertMode: Bool, environment: [String: String], currentDirectory: URL) throws {
    self.assertMode = assertMode
    self.environment = environment
    self.repoRoot = try Self.resolveRepoRoot(startingAt: currentDirectory)
    self.projectDir = URL(
      fileURLWithPath: environment["HARNESS_E2E_PROJECT_DIR"] ?? repoRoot.path,
      isDirectory: true
    )
    self.commonRepoRoot = try Self.resolveCommonRepoRoot(startingAt: repoRoot)
    self.appRoot = repoRoot.appendingPathComponent("apps/harness-monitor-macos", isDirectory: true)

    let resolvedRunID = environment["HARNESS_E2E_RUN_ID"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let runID =
      (resolvedRunID?.isEmpty == false ? resolvedRunID : nil)
      ?? UUID().uuidString.lowercased()
    let tmpDirectory = URL(
      fileURLWithPath: environment["TMPDIR"] ?? NSTemporaryDirectory(),
      isDirectory: true
    )
    let stateRootOverride = environment["HARNESS_E2E_STATE_ROOT"].flatMap {
      $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
    }
    let dataRootOverride = environment["HARNESS_E2E_DATA_ROOT"].flatMap {
      $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
    }
    let dataHomeOverride = environment["HARNESS_E2E_DATA_HOME"].flatMap {
      $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
    }
    let syncRootOverride = environment["HARNESS_E2E_SYNC_ROOT"].flatMap {
      $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
    }
    let runnerContainerRootOverride = environment[SwarmRunLayout.runnerContainerEnvironmentKey]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    let triageRootOverride = environment["HARNESS_E2E_TRIAGE_ROOT"].flatMap {
      $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
    }

    self.layout = SwarmRunLayout(
      runID: runID,
      repoRoot: repoRoot,
      commonRepoRoot: commonRepoRoot,
      temporaryDirectory: tmpDirectory,
      homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
      sessionID: environment["HARNESS_E2E_SESSION_ID"],
      stateRootOverride: stateRootOverride,
      dataRootOverride: dataRootOverride,
      dataHomeOverride: dataHomeOverride,
      runnerContainerRootOverride: runnerContainerRootOverride,
      syncRootOverride: syncRootOverride,
      triageRootOverride: triageRootOverride
    )

    self.destination =
      environment["HARNESS_MONITOR_XCODEBUILD_DESTINATION"]
      ?? environment["XCODEBUILD_DESTINATION"]
      ?? Self.defaultDestination()
    self.onlyTesting =
      environment["XCODE_ONLY_TESTING"]
      ?? "HarnessMonitorAgentsE2ETests/SwarmFullFlowTests/testSwarmFullFlow"
    self.keepData = environment["HARNESS_E2E_KEEP_DATA"] == "1"
    self.harnessBinary = try Self.resolveHarnessBinary(repoRoot: repoRoot, environment: environment)
    self.helperBinary = URL(
      fileURLWithPath: environment["HARNESS_MONITOR_E2E_TOOL_BINARY"] ?? CommandLine.arguments[0])
    self.client = HarnessClient(binary: harnessBinary, dataHome: layout.dataHome)
    self.startedAt = Date()
  }

  func run() throws -> Int32 {
    var status: Int32 = 0
    var errorDescription: String?

    do {
      try execute()
    } catch let failure as CommandFailure {
      status = failure.status
      errorDescription = failure.description
    } catch {
      status = 1
      errorDescription = String(describing: error)
    }

    if let errorDescription, status != 0 {
      fputs("\(errorDescription)\n", stderr)
    }
    return cleanup(status: status)
  }

  private func execute() throws {
    try createDirectories()
    _ = try SwarmSeedState.seed(dataHome: layout.dataHome)

    let probeReport = SwarmRuntimeProbe(environment: environment).run()
    try write(
      data: SwarmRuntimeProbe.encoded(probeReport),
      to: layout.stateRoot.appendingPathComponent("probe.json"))
    if !probeReport.requiredMissing.isEmpty {
      throw CommandFailure(
        status: 1,
        message: "required runtimes missing: \(probeReport.requiredMissing.joined(separator: ", "))"
      )
    }

    try runLoggedCommand(
      executable: appRoot.appendingPathComponent("Scripts/generate.sh"),
      arguments: [],
      logURL: layout.generateLog
    )
    try runLoggedCommand(
      executable: repoRoot.appendingPathComponent("scripts/cargo-local.sh"),
      arguments: ["build", "--bin", "harness"],
      logURL: layout.harnessBuildLog
    )

    let xcodebuildRunner = appRoot.appendingPathComponent("Scripts/xcodebuild-with-lock.sh")
    let testArgs = [
      "-workspace", appRoot.appendingPathComponent("HarnessMonitor.xcworkspace").path,
      "-scheme", "HarnessMonitorAgentsE2E",
      "-destination", destination,
      "-derivedDataPath", layout.derivedDataPath.path,
      "CODE_SIGNING_ALLOWED=YES",
      "build-for-testing",
    ]
    try runLoggedCommand(
      executable: xcodebuildRunner,
      arguments: testArgs,
      environment: [
        "HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE": "1"
      ],
      logURL: layout.buildXcodebuildLog
    )

    let generatedXctestrun = try locateGeneratedXctestrun()
    let configuredXctestrun = generatedXctestrun.deletingPathExtension()
      .appendingPathExtension("swarm.configured.xctestrun")
    try XctestrunConfigurator.configure(
      source: generatedXctestrun,
      destination: configuredXctestrun,
      updates: [
        "HARNESS_MONITOR_ENABLE_SWARM_E2E": "1",
        "HARNESS_MONITOR_SWARM_E2E_STATE_ROOT": layout.stateRoot.path,
        "HARNESS_MONITOR_SWARM_E2E_DATA_HOME": layout.dataHome.path,
        "HARNESS_MONITOR_SWARM_E2E_DAEMON_LOG": layout.daemonLog.path,
        "HARNESS_MONITOR_SWARM_E2E_SESSION_ID": layout.sessionID,
        "HARNESS_MONITOR_SWARM_E2E_SYNC_DIR": layout.syncDir.path,
        SwarmStepTimeouts.environmentKey: SwarmStepTimeouts.encodedEnvironmentValue,
        SwarmStepTimeouts.maxRecordingSecondsKey: String(
          Int(SwarmStepTimeouts.maxRecordingDuration)),
        "HARNESS_MONITOR_UI_TEST_RECORDING_CONTROL_DIR": layout.screenRecordingControlDirectory
          .path,
        "HARNESS_MONITOR_UI_TEST_ARTIFACTS_DIR": layout.uiSnapshotsSource.path,
      ]
    )

    daemonProcess = try DaemonSpawner.spawn(client: client, logURL: layout.daemonLog)
    try startActDriver(probeJSON: layout.stateRoot.appendingPathComponent("probe.json"))
    try startScreenRecording()
    defer { stopScreenRecording() }

    let testStatus = try runLoggedCommand(
      executable: xcodebuildRunner,
      arguments: [
        "-xctestrun", configuredXctestrun.path,
        "-resultBundlePath", layout.resultBundlePath.path,
        "-destination", destination,
        "CODE_SIGNING_ALLOWED=YES",
        "test-without-building",
        "-only-testing:\(onlyTesting)",
      ],
      environment: [
        "HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE": "1",
        "HARNESS_MONITOR_TEST_RETRY_ITERATIONS": "0",
      ],
      logURL: layout.testXcodebuildLog,
      allowFailure: true,
      terminationTrigger: actDriverFailureReason
    )
    if let actDriverProcess, !actDriverProcess.isRunning, actDriverProcess.terminationStatus != 0 {
      throw CommandFailure(
        status: actDriverProcess.terminationStatus,
        message: "swarm act driver failed"
      )
    }
    if testStatus != 0 {
      throw CommandFailure(status: testStatus, message: "swarm full-flow xcodebuild failed")
    }

    if let actDriverProcess {
      actDriverProcess.waitUntilExit()
      guard actDriverProcess.terminationStatus == 0 else {
        throw CommandFailure(
          status: actDriverProcess.terminationStatus,
          message: "swarm act driver failed"
        )
      }
      self.actDriverProcess = nil
    }

    try verifyFinalState()
  }

  private func cleanup(status: Int32) -> Int32 {
    var finalStatus = status
    let endedAt = Date()
    stopScreenRecording()

    if let actDriverProcess {
      ProcessCleanup.terminateTree(rootPID: actDriverProcess.processIdentifier)
      self.actDriverProcess = nil
    }
    if let daemonProcess {
      ProcessCleanup.terminateTree(rootPID: daemonProcess.processIdentifier)
      self.daemonProcess = nil
    }

    let triageStatus = runTriage(status: status, endedAt: endedAt)
    if finalStatus == 0, triageStatus != 0 {
      finalStatus = triageStatus
    }

    if finalStatus == 0, !keepData {
      try? FileManager.default.removeItem(at: layout.syncRoot)
      try? FileManager.default.removeItem(at: layout.stateRoot)
    }

    fputs("Swarm e2e artifacts recorded at: \(layout.artifactsDir.path)\n", stderr)
    fputs("Swarm e2e triage findings: \(layout.findingsFile.path)\n", stderr)
    if finalStatus == 0, !keepData {
      fputs(
        "Swarm e2e temp state copied into artifacts and cleaned from: \(layout.stateRoot.path)\n",
        stderr)
      fputs(
        "Swarm e2e temp sync copied into artifacts and cleaned from: \(layout.syncRoot.path)\n",
        stderr)
    } else {
      fputs("Swarm e2e state preserved at: \(layout.stateRoot.path)\n", stderr)
      fputs("Swarm e2e sync preserved at: \(layout.syncRoot.path)\n", stderr)
    }
    printTail(label: "daemon log tail", url: layout.daemonLog, limit: 80)
    printTail(label: "act driver log tail", url: layout.actDriverLog, limit: 120)
    return finalStatus
  }

  private func createDirectories() throws {
    try FileManager.default.createDirectory(at: layout.dataHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: layout.syncDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: layout.logRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: layout.uiSnapshotsSource, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: layout.screenRecordingControlDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: layout.findingsFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: layout.stateRoot, withIntermediateDirectories: true)
  }

  private func startActDriver(probeJSON: URL) throws {
    let logHandle = try makeTruncatedFileHandle(at: layout.actDriverLog)
    defer { try? logHandle.close() }

    let process = Process()
    process.executableURL = helperBinary
    process.arguments = [
      "swarm-act-driver",
      "--repo-root", repoRoot.path,
      "--state-root", layout.stateRoot.path,
      "--data-home", layout.dataHome.path,
      "--project-dir", projectDir.path,
      "--sync-dir", layout.syncDir.path,
      "--session-id", layout.sessionID,
      "--harness-binary", harnessBinary.path,
      "--probe-json", probeJSON.path,
    ]
    process.standardOutput = logHandle
    process.standardError = logHandle
    try process.run()
    actDriverProcess = process
  }

  private func startScreenRecording() throws {
    FileManager.default.createFile(atPath: layout.screenRecordingLog.path, contents: nil)
    let process = Process()
    process.executableURL = helperBinary
    process.arguments = [
      "start-recording",
      "--output", layout.screenRecordingPath.path,
      "--log", layout.screenRecordingLog.path,
      "--manifest", layout.screenRecordingManifestPath.path,
      "--control-dir", layout.screenRecordingControlDirectory.path,
      "--max-seconds", String(Int(SwarmStepTimeouts.maxRecordingDuration)),
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    Thread.sleep(forTimeInterval: 0.2)
    guard process.isRunning else {
      throw CommandFailure(status: process.terminationStatus, message: "start-recording failed")
    }
    screenRecordingProcess = process
  }

  private func stopScreenRecording() {
    guard screenRecordingProcess != nil else { return }
    if FileManager.default.fileExists(atPath: layout.screenRecordingManifestPath.path),
      let manifest = try? ScreenRecordingManifest.load(from: layout.screenRecordingManifestPath)
    {
      ScreenRecordingStopper.stop(manifest: manifest)
      try? FileManager.default.removeItem(at: layout.screenRecordingManifestPath)
    }
    if let process = screenRecordingProcess, process.isRunning {
      process.interrupt()
      process.waitUntilExit()
    }
    screenRecordingProcess = nil
  }

  private func locateGeneratedXctestrun() throws -> URL {
    let products = layout.derivedDataPath.appendingPathComponent(
      "Build/Products", isDirectory: true)
    let contents = try FileManager.default.contentsOfDirectory(
      at: products, includingPropertiesForKeys: nil)
    let candidates =
      contents
      .filter {
        $0.lastPathComponent.hasPrefix("HarnessMonitorAgentsE2E_")
          && $0.pathExtension == "xctestrun"
          && !$0.lastPathComponent.hasSuffix(".configured.xctestrun")
      }
      .sorted { $0.path < $1.path }
    guard let latest = candidates.last else {
      throw CommandFailure(
        status: 1, message: "Failed to locate generated HarnessMonitorAgentsE2E .xctestrun file")
    }
    return latest
  }

  private func verifyFinalState() throws {
    guard assertMode else { return }
    let result = client.run([
      "session", "status", layout.sessionID,
      "--json",
      "--project-dir", projectDir.path,
    ])
    guard result.exitStatus == 0 else {
      throw CommandFailure(
        status: result.exitStatus, message: "failed to fetch final swarm session status")
    }
    let finalJSON = layout.stateRoot.appendingPathComponent("final-status.json")
    try write(data: result.stdout, to: finalJSON)
    guard
      let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
      let status = json["status"] as? String,
      status == "ended"
    else {
      throw CommandFailure(status: 1, message: "swarm final status was not ended")
    }
    let tasks = json["tasks"] as? [[String: Any]] ?? []
    let hasArbitration = tasks.contains {
      $0["arbitration"] != nil && !($0["arbitration"] is NSNull)
    }
    let hasObserveTask = tasks.contains { ($0["source"] as? String) == "observe" }
    guard hasArbitration, hasObserveTask else {
      throw CommandFailure(
        status: 1, message: "swarm final status missing expected arbitration or observe tasks")
    }

    let gapsResult = try runCapturedCommand(
      executable: repoRoot.appendingPathComponent("scripts/e2e/gaps-open-count.sh"),
      arguments: []
    )
    let openGaps = String(data: gapsResult.stdout, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard openGaps == "0" else {
      throw CommandFailure(status: 1, message: "open swarm gaps remain: \(openGaps ?? "<unknown>")")
    }
  }

  private func runTriage(status: Int32, endedAt: Date) -> Int32 {
    let durationSeconds = max(0, Int(endedAt.timeIntervalSince(startedAt)))
    let result = try? runCapturedCommand(
      executable: repoRoot.appendingPathComponent("scripts/e2e/triage-run.sh"),
      arguments: [
        "--scenario", "swarm-full-flow",
        "--run-id", layout.runID,
        "--artifacts-dir", layout.artifactsDir.path,
        "--findings-file", layout.findingsFile.path,
        "--exit-code", String(status),
        "--started-at", SwarmRunLayout.timestampUTC(date: startedAt),
        "--ended-at", SwarmRunLayout.timestampUTC(date: endedAt),
        "--duration-seconds", String(durationSeconds),
        "--session-id", layout.sessionID,
        "--state-root", layout.stateRoot.path,
        "--sync-root", layout.syncRoot.path,
        "--ui-snapshots-source", layout.uiSnapshotsSource.path,
        "--result-bundle", layout.resultBundlePath.path,
        "--recording", layout.screenRecordingPath.path,
        "--log", layout.daemonLog.path,
        "--log", layout.actDriverLog.path,
        "--log", layout.buildXcodebuildLog.path,
        "--log", layout.testXcodebuildLog.path,
        "--log", layout.screenRecordingLog.path,
      ]
    )
    return result?.exitStatus ?? 1
  }

  @discardableResult
  private func runLoggedCommand(
    executable: URL,
    arguments: [String],
    environment extraEnvironment: [String: String] = [:],
    logURL: URL,
    allowFailure: Bool = false,
    terminationTrigger: (() -> String?)? = nil
  ) throws -> Int32 {
    let result = try LoggedProcessRunner(environment: environment).run(
      executable: executable,
      arguments: arguments,
      environment: extraEnvironment,
      logURL: logURL,
      terminationTrigger: terminationTrigger
    )
    if result.exitStatus != 0, !allowFailure {
      throw CommandFailure(
        status: result.exitStatus,
        message: result.terminationReason
          ?? "\(executable.lastPathComponent) failed with status \(result.exitStatus)"
      )
    }
    return result.exitStatus
  }

  private func runCapturedCommand(
    executable: URL,
    arguments: [String]
  ) throws -> CommandResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return CommandResult(
      exitStatus: process.terminationStatus,
      stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
      stderr: stderr.fileHandleForReading.readDataToEndOfFile()
    )
  }

  private func write(data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private func printTail(label: String, url: URL, limit: Int) {
    guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let tail = lines.suffix(limit).joined(separator: "\n")
    fputs("--- \(label) ---\n\(tail)\n", stderr)
  }

  private func actDriverFailureReason() -> String? {
    guard let actDriverProcess, !actDriverProcess.isRunning else {
      return nil
    }
    guard actDriverProcess.terminationStatus != 0 else {
      return nil
    }
    return "swarm act driver failed"
  }

  private static func resolveRepoRoot(startingAt currentDirectory: URL) throws -> URL {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", currentDirectory.path, "rev-parse", "--show-toplevel"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0,
        let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        text.isEmpty == false
      {
        return URL(fileURLWithPath: text, isDirectory: true)
      }
    } catch {}
    return currentDirectory
  }

  private static func resolveCommonRepoRoot(startingAt repoRoot: URL) throws -> URL {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
      "-C", repoRoot.path, "rev-parse", "--path-format=absolute", "--git-common-dir",
    ]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0,
        let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        text.isEmpty == false
      {
        return URL(fileURLWithPath: text, isDirectory: true).deletingLastPathComponent()
      }
    } catch {}
    return repoRoot
  }

  private static func resolveHarnessBinary(repoRoot: URL, environment: [String: String]) throws
    -> URL
  {
    if let override = environment["HARNESS_E2E_HARNESS_BINARY"], override.isEmpty == false {
      return URL(fileURLWithPath: override)
    }

    let process = Process()
    process.executableURL = repoRoot.appendingPathComponent("scripts/cargo-local.sh")
    process.arguments = ["--print-env"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let text =
      String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("CARGO_TARGET_DIR=") })
    else {
      throw CommandFailure(status: 1, message: "error: failed to resolve CARGO_TARGET_DIR")
    }
    let value = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[1]
    return URL(fileURLWithPath: String(value), isDirectory: true)
      .appendingPathComponent("debug/harness")
  }

  private static func defaultDestination() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    switch machine {
    case "arm64", "x86_64":
      return "platform=macOS,arch=\(machine),name=My Mac"
    default:
      return "platform=macOS,name=My Mac"
    }
  }

  private func makeTruncatedFileHandle(at url: URL) throws -> FileHandle {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try FileHandle(forWritingTo: url)
  }
}

private final class SwarmActDriverRunner {
  private struct Failure: Error, CustomStringConvertible {
    let status: Int32
    let message: String

    var description: String { message }
  }

  private let inputs: SwarmActDriverInputs
  private let client: HarnessClient
  private let probeReport: SwarmRuntimeProbe.Report
  private let appendGapScript: URL
  private let improverSource: URL
  private let progressHandle: FileHandle?

  init(inputs: SwarmActDriverInputs) throws {
    self.inputs = inputs
    self.client = HarnessClient(binary: inputs.harnessBinary, dataHome: inputs.dataHome)
    let probeData = try Data(contentsOf: inputs.probeJSON)
    self.probeReport = try JSONDecoder().decode(SwarmRuntimeProbe.Report.self, from: probeData)
    self.appendGapScript = inputs.repoRoot.appendingPathComponent("scripts/e2e/append-gap.sh")
    self.improverSource = inputs.repoRoot
      .appendingPathComponent("agents/plugins/harness/skills/harness/body.md")
    if let progressLog = inputs.progressLog {
      try FileManager.default.createDirectory(
        at: progressLog.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: progressLog.path) {
        FileManager.default.createFile(atPath: progressLog.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: progressLog)
      try? handle.seekToEnd()
      self.progressHandle = handle
    } else {
      self.progressHandle = nil
    }
  }

  func run() throws {
    logProgress("started")

    logProgress("step=session-start session=\(inputs.sessionID)")
    try runHarness([
      "session", "start",
      "--project-dir", inputs.projectDir.path,
      "--session-id", inputs.sessionID,
      "--title", "swarm",
      "--context", "e2e swarm full flow",
    ])

    let leaderID = try joinAgent(
      role: "leader", runtime: "claude", name: "Swarm Leader", persona: "architect")
    try actReady("act1", values: ["session_id": inputs.sessionID, "leader_id": leaderID])
    try actAck("act1")

    let workerCodexID = try joinAgent(
      role: "worker", runtime: "codex", name: "Swarm Worker Codex", persona: "test-writer")
    let workerClaudeID = try joinAgent(
      role: "worker", runtime: "claude", name: "Swarm Worker Claude", persona: "code-reviewer")
    let reviewerClaudeID = try joinAgent(
      role: "reviewer", runtime: "claude", name: "Swarm Reviewer Claude", persona: "code-reviewer")
    let reviewerCodexID = try joinAgent(
      role: "reviewer", runtime: "codex", name: "Swarm Reviewer Codex", persona: "code-reviewer")
    let reviewerDuplicateClaudeID = try joinAgent(
      role: "reviewer", runtime: "claude", name: "Swarm Reviewer Claude Duplicate",
      persona: "code-reviewer")
    let observerID = try joinAgent(
      role: "observer", runtime: "claude", name: "Swarm Observer", persona: "debugger")
    let improverID = try joinAgent(
      role: "improver", runtime: "codex", name: "Swarm Improver", persona: "architect")

    if runtimeAvailable("gemini") {
      _ = try joinAgent(
        role: "observer", runtime: "gemini", name: "Swarm Observer Gemini", persona: "debugger")
    } else {
      try appendOptionalSkip("gemini")
    }
    if runtimeAvailable("copilot") {
      _ = try joinAgent(
        role: "improver", runtime: "copilot", name: "Swarm Improver Copilot", persona: "architect")
    } else {
      try appendOptionalSkip("copilot")
    }
    let vibeWorkerID: String
    if runtimeAvailable("vibe") {
      vibeWorkerID = try joinAgent(
        role: "worker", runtime: "vibe", name: "Swarm Worker Vibe", persona: "generalist")
    } else {
      vibeWorkerID = ""
      try appendOptionalSkip("vibe")
    }
    if !runtimeAvailable("opencode") {
      try appendOptionalSkip("opencode")
    }

    try actReady(
      "act2",
      values: [
        "worker_codex_id": workerCodexID,
        "worker_claude_id": workerClaudeID,
        "reviewer_claude_id": reviewerClaudeID,
        "reviewer_codex_id": reviewerCodexID,
        "observer_id": observerID,
        "improver_id": improverID,
      ])
    try actAck("act2")

    let taskReviewID = try createTask(
      title: "Review full-flow task", severity: "high", leaderID: leaderID)
    let taskAutospawnID = try createTask(
      title: "Auto-spawn reviewer task", severity: "medium", leaderID: leaderID)
    let taskArbitrationID = try createTask(
      title: "Arbitration review task", severity: "high", leaderID: leaderID)
    let taskRefusalID = try createTask(
      title: "Busy worker refusal task", severity: "low", leaderID: leaderID)
    let taskSignalID = try createTask(
      title: "Signal collision task", severity: "medium", leaderID: leaderID)
    try actReady(
      "act3",
      values: [
        "task_review_id": taskReviewID,
        "task_autospawn_id": taskAutospawnID,
        "task_arbitration_id": taskArbitrationID,
        "task_refusal_id": taskRefusalID,
        "task_signal_id": taskSignalID,
      ])
    try actAck("act3")

    try assignAndStart(taskID: taskReviewID, agentID: workerCodexID, leaderID: leaderID)
    try assignAndStart(taskID: taskAutospawnID, agentID: workerClaudeID, leaderID: leaderID)
    try actReady(
      "act4",
      values: [
        "task_review_id": taskReviewID,
        "task_autospawn_id": taskAutospawnID,
      ])
    try actAck("act4")

    for code in [
      "python_traceback_output",
      "unauthorized_git_commit_during_run",
      "python_used_in_bash_tool_use",
      "absolute_manifest_path_used",
      "jq_error_in_command_output",
      "unverified_recursive_remove",
      "hook_denied_tool_call",
      "agent_repeated_error",
      "agent_stalled_progress",
      "cross_agent_file_conflict",
    ] {
      _ = try SwarmHeuristicInjection.append(
        .init(
          code: code,
          agentID: observerID,
          sessionID: inputs.sessionID,
          projectDir: inputs.projectDir,
          dataHome: inputs.dataHome,
          harnessBinary: inputs.harnessBinary
        ))
    }
    _ = runHarnessMayFail([
      "session", "observe", inputs.sessionID,
      "--json",
      "--actor", observerID,
      "--project-dir", inputs.projectDir.path,
    ])
    try actReady(
      "act5",
      values: [
        "observer_id": observerID,
        "heuristic_code": "python_traceback_output",
      ])
    try actAck("act5")

    let improverContents = inputs.stateRoot.appendingPathComponent("improver-body.md")
    try FileManager.default.copyItem(at: improverSource, to: improverContents)
    try runHarness([
      "session", "improver", "apply", inputs.sessionID,
      "--project-dir", inputs.projectDir.path,
      "--actor", improverID,
      "--issue-id", "python_traceback_output/e2e",
      "--target", "plugin",
      "--rel-path", "harness/skills/harness/body.md",
      "--new-contents-file", improverContents.path,
      "--dry-run",
    ])
    try actReady("act6", values: ["improver_id": improverID])
    try actAck("act6")

    var currentVibeWorkerID = vibeWorkerID
    if !currentVibeWorkerID.isEmpty {
      _ = runHarnessMayFail([
        "session", "leave", inputs.sessionID, currentVibeWorkerID, "--project-dir",
        inputs.projectDir.path,
      ])
      currentVibeWorkerID = try joinAgent(
        role: "worker", runtime: "vibe", name: "Swarm Worker Vibe Rejoined", persona: "generalist")
    }
    try runHarness([
      "session", "sync", inputs.sessionID, "--json", "--project-dir", inputs.projectDir.path,
    ])
    let temporaryWorkerID = try joinAgent(
      role: "worker", runtime: "claude", name: "Swarm Temporary Worker", persona: "generalist")
    try runHarness([
      "session", "leave", inputs.sessionID, temporaryWorkerID, "--project-dir",
      inputs.projectDir.path,
    ])
    try actReady("act7", values: ["vibe_worker_id": currentVibeWorkerID])
    try actAck("act7")

    try runHarness([
      "session", "task", "submit-for-review", inputs.sessionID, taskReviewID,
      "--project-dir", inputs.projectDir.path,
      "--actor", workerCodexID,
      "--summary", "ready",
    ])
    try actReady(
      "act8",
      values: [
        "task_review_id": taskReviewID,
        "worker_codex_id": workerCodexID,
      ])
    try actAck("act8")

    try runHarness([
      "session", "task", "claim-review", inputs.sessionID, taskReviewID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerClaudeID,
    ])
    let duplicateClaim = runHarnessMayFail([
      "session", "task", "claim-review", inputs.sessionID, taskReviewID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerDuplicateClaudeID,
    ])
    if duplicateClaim.exitStatus == 0 {
      throw Failure(
        status: 1, message: "duplicate same-runtime review claim unexpectedly succeeded")
    }
    try runHarness([
      "session", "task", "claim-review", inputs.sessionID, taskReviewID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerCodexID,
    ])
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskReviewID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerClaudeID,
      "--verdict", "approve",
      "--summary", "LGTM",
    ])
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskReviewID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerCodexID,
      "--verdict", "approve",
      "--summary", "LGTM",
    ])
    try actReady(
      "act9",
      values: [
        "task_review_id": taskReviewID,
        "reviewer_runtime": "claude",
      ])
    try actAck("act9")

    _ = runHarnessMayFail([
      "session", "remove", inputs.sessionID, reviewerClaudeID, "--project-dir",
      inputs.projectDir.path, "--actor", leaderID,
    ])
    _ = runHarnessMayFail([
      "session", "remove", inputs.sessionID, reviewerCodexID, "--project-dir",
      inputs.projectDir.path, "--actor", leaderID,
    ])
    _ = runHarnessMayFail([
      "session", "remove", inputs.sessionID, reviewerDuplicateClaudeID, "--project-dir",
      inputs.projectDir.path, "--actor", leaderID,
    ])
    try runHarness([
      "session", "task", "submit-for-review", inputs.sessionID, taskAutospawnID,
      "--project-dir", inputs.projectDir.path,
      "--actor", workerClaudeID,
      "--summary", "ready",
    ])
    try runHarness([
      "session", "signal", "list", inputs.sessionID, "--json", "--project-dir",
      inputs.projectDir.path,
    ])
    try actReady(
      "act10",
      values: [
        "task_autospawn_id": taskAutospawnID,
        "worker_claude_id": workerClaudeID,
      ])
    try actAck("act10")

    let refusalResult = runHarnessMayFail([
      "session", "task", "assign", inputs.sessionID, taskRefusalID, workerClaudeID,
      "--project-dir", inputs.projectDir.path,
      "--actor", leaderID,
    ])
    if refusalResult.exitStatus == 0 {
      throw Failure(status: 1, message: "awaiting-review worker assignment unexpectedly succeeded")
    }
    try actReady(
      "act11",
      values: [
        "task_refusal_id": taskRefusalID,
        "worker_claude_id": workerClaudeID,
      ])
    try actAck("act11")

    let reviewerRoundClaudeID = try joinAgent(
      role: "reviewer", runtime: "claude", name: "Swarm Reviewer Claude Round",
      persona: "code-reviewer")
    let reviewerRoundCodexID = try joinAgent(
      role: "reviewer", runtime: "codex", name: "Swarm Reviewer Codex Round",
      persona: "code-reviewer")
    try assignAndStart(taskID: taskArbitrationID, agentID: workerCodexID, leaderID: leaderID)
    try submitRequestChangesRound(
      taskID: taskArbitrationID, workerID: workerCodexID, reviewerA: reviewerRoundClaudeID,
      reviewerB: reviewerRoundCodexID, note: "redoing")
    try actReady(
      "act12",
      values: [
        "task_arbitration_id": taskArbitrationID,
        "point_id": "p1",
      ])
    try actAck("act12")

    _ = runHarnessMayFail([
      "session", "task", "update", inputs.sessionID, taskArbitrationID,
      "--project-dir", inputs.projectDir.path,
      "--status", "in_progress",
      "--actor", workerCodexID,
    ])
    try submitRequestChangesRound(
      taskID: taskArbitrationID, workerID: workerCodexID, reviewerA: reviewerRoundClaudeID,
      reviewerB: reviewerRoundCodexID, note: "round two")
    _ = runHarnessMayFail([
      "session", "task", "update", inputs.sessionID, taskArbitrationID,
      "--project-dir", inputs.projectDir.path,
      "--status", "in_progress",
      "--actor", workerCodexID,
    ])
    try submitRequestChangesRound(
      taskID: taskArbitrationID, workerID: workerCodexID, reviewerA: reviewerRoundClaudeID,
      reviewerB: reviewerRoundCodexID, note: "round three")
    _ = SwarmContractCommands.taskArbitrate
    try runHarness([
      "session", "task", "arbitrate", inputs.sessionID, taskArbitrationID,
      "--project-dir", inputs.projectDir.path,
      "--actor", leaderID,
      "--verdict", "approve",
      "--summary", "shipping",
    ])
    try actReady("act13", values: ["task_arbitration_id": taskArbitrationID])
    try actAck("act13")

    try runHarness([
      "session", "signal", "send", inputs.sessionID, workerCodexID,
      "--project-dir", inputs.projectDir.path,
      "--command", "pause",
      "--message", "test",
      "--actor", leaderID,
    ])
    _ = runHarnessMayFail([
      "session", "signal", "send", inputs.sessionID, workerCodexID,
      "--project-dir", inputs.projectDir.path,
      "--command", "pause",
      "--message", "test",
      "--actor", leaderID,
    ])
    try actReady("act14", values: ["agent_id": workerCodexID])
    try actAck("act14")

    _ = runHarnessMayFail([
      "observe", "scan", inputs.sessionID,
      "--json",
      "--project-hint", inputs.projectDir.lastPathComponent,
    ])
    _ = runHarnessMayFail([
      "observe", "watch", inputs.sessionID,
      "--timeout", "5",
      "--json",
      "--project-hint", inputs.projectDir.lastPathComponent,
    ])
    _ = runHarnessMayFail([
      "observe", "dump", inputs.sessionID,
      "--raw-json",
      "--project-hint", inputs.projectDir.lastPathComponent,
    ])
    _ = SwarmContractCommands.observeDoctorJSON
    try runHarness([
      "observe", "doctor",
      "--json",
      "--project-dir", inputs.projectDir.path,
    ])
    try actReady("act15", values: ["session_id": inputs.sessionID])
    try actAck("act15")

    try runHarness([
      "session", "end", inputs.sessionID,
      "--project-dir", inputs.projectDir.path,
      "--actor", leaderID,
    ])
    try actReady("act16", values: ["session_id": inputs.sessionID])
    try actAck("act16")

    print("act driver finished")
  }

  private func runtimeAvailable(_ name: String) -> Bool {
    probeReport.runtimes[name]?.available == true
  }

  private func appendOptionalSkip(_ runtime: String) throws {
    let process = Process()
    process.executableURL = appendGapScript
    process.arguments = [
      "--id", "SKIP-\(runtime)",
      "--status", "Closed",
      "--severity", "low",
      "--subsystem", "runtime-probe",
      "--current", "optional runtime \(runtime) unavailable in this environment",
      "--desired", "optional runtime absence is documented and non-blocking",
      "--closed-by", "runtime probe",
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure(status: process.terminationStatus, message: "append-gap failed for \(runtime)")
    }
  }

  private func joinAgent(role: String, runtime: String, name: String, persona: String) throws
    -> String
  {
    let output = try runHarness([
      "session", "join", inputs.sessionID,
      "--project-dir", inputs.projectDir.path,
      "--role", role,
      "--runtime", runtime,
      "--name", name,
      "--persona", persona,
    ])
    guard let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
      throw Failure(status: 1, message: "failed to decode joined agent state for \(name)")
    }
    if let agentsByID = json["agents"] as? [String: Any] {
      for (agentID, rawAgent) in agentsByID {
        guard let agent = rawAgent as? [String: Any], (agent["name"] as? String) == name else {
          continue
        }
        if let explicitID = agent["agent_id"] as? String, !explicitID.isEmpty {
          return explicitID
        }
        return agentID
      }
    }
    if let agents = json["agents"] as? [[String: Any]],
      let agentID = agents.reversed().first(where: { ($0["name"] as? String) == name })?["agent_id"]
        as? String
    {
      return agentID
    }
    throw Failure(status: 1, message: "failed to resolve joined agent \(name)")
  }

  private func createTask(title: String, severity: String, leaderID: String) throws -> String {
    let output = try runHarness([
      "session", "task", "create", inputs.sessionID,
      "--project-dir", inputs.projectDir.path,
      "--title", title,
      "--severity", severity,
      "--actor", leaderID,
    ])
    guard
      let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
      let taskID = json["task_id"] as? String
    else {
      throw Failure(status: 1, message: "failed to create task \(title)")
    }
    return taskID
  }

  private func assignAndStart(taskID: String, agentID: String, leaderID: String) throws {
    try runHarness([
      "session", "task", "assign", inputs.sessionID, taskID, agentID,
      "--project-dir", inputs.projectDir.path,
      "--actor", leaderID,
    ])
    try runHarness([
      "session", "task", "update", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--status", "in_progress",
      "--actor", agentID,
    ])
  }

  private func submitRequestChangesRound(
    taskID: String,
    workerID: String,
    reviewerA: String,
    reviewerB: String,
    note: String
  ) throws {
    let points =
      #"[{"point_id":"p1","text":"A","state":"open"},{"point_id":"p2","text":"B","state":"open"},{"point_id":"p3","text":"C","state":"open"}]"#
    try runHarness([
      "session", "task", "submit-for-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", workerID,
      "--summary", "ready for review",
    ])
    _ = runHarnessMayFail([
      "session", "task", "claim-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerA,
    ])
    _ = runHarnessMayFail([
      "session", "task", "claim-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerB,
    ])
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerA,
      "--verdict", "request_changes",
      "--summary", "changes requested",
      "--points", points,
    ])
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerB,
      "--verdict", "request_changes",
      "--summary", "changes requested",
      "--points", points,
    ])
    try runHarness([
      "session", "task", "respond-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", workerID,
      "--agreed", "p1",
      "--disputed", "p2,p3",
      "--note", note,
    ])
  }

  private func actReady(_ act: String, values: [String: String]) throws {
    let marker = inputs.syncDir.appendingPathComponent("\(act).ready")
    try FileManager.default.createDirectory(
      at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    var body = "act=\(act)\n"
    for key in values.keys.sorted() {
      guard let value = values[key] else { continue }
      body.append("\(key)=\(value)\n")
    }
    try Data(body.utf8).write(to: marker, options: .atomic)
    logProgress("step=ready act=\(act) marker=\(marker.path)")
  }

  private func actAck(_ act: String, timeout: TimeInterval? = nil) throws {
    let marker = inputs.syncDir.appendingPathComponent("\(act).ack")
    let stopMarker = inputs.syncDir
      .deletingLastPathComponent()
      .appendingPathComponent("recording-control/stop.request")
    let resolvedTimeout =
      timeout
      ?? inputs.stepTimeoutOverrides[act]
      ?? SwarmStepTimeouts.timeout(for: act)
    logProgress("step=await-ack act=\(act) timeout=\(resolvedTimeout)s")
    let outcome: SwarmAckWait.Outcome
    do {
      outcome = try SwarmAckWait.waitForAck(
        ackExists: { FileManager.default.fileExists(atPath: marker.path) },
        stopRequested: { FileManager.default.fileExists(atPath: stopMarker.path) },
        timeout: resolvedTimeout
      )
    } catch SwarmAckWait.Failure.timedOut {
      logProgress("step=ack-timeout act=\(act) timeout=\(resolvedTimeout)s")
      throw Failure(
        status: 1,
        message: "\(act).ack timed out after \(Int(resolvedTimeout))s waiting at \(marker.path)"
      )
    }
    switch outcome {
    case .acknowledged:
      logProgress("step=ack act=\(act)")
    case .stopped:
      throw Failure(status: 1, message: "UI test ended before \(act).ack")
    }
  }

  private func logProgress(_ message: String) {
    let timestamp = Self.progressTimestamp(date: Date())
    let line = "[swarm-act-driver] \(timestamp) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
    if let progressHandle {
      try? progressHandle.write(contentsOf: data)
    }
  }

  private static func progressTimestamp(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
  }

  @discardableResult
  private func runHarness(_ arguments: [String]) throws -> HarnessClient.Output {
    let result = client.run(arguments)
    guard result.exitStatus == 0 else {
      let stderr = String(data: result.stderr, encoding: .utf8) ?? "<binary>"
      throw Failure(
        status: result.exitStatus,
        message: "harness \(arguments.joined(separator: " ")) failed: \(stderr)")
    }
    return result
  }

  private func runHarnessMayFail(_ arguments: [String]) -> HarnessClient.Output {
    client.run(arguments)
  }
}
