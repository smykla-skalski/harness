import Foundation
import Testing
@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Harness Monitor startup log navigation regressions")
struct HarnessMonitorStoreNavigationStartupLogTests {
  @Test("Launching the isolated host does not emit FocusedValue startup warnings")
  func launchDoesNotEmitFocusedValueWarning() async throws {
    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "HarnessMonitorFocusedValueLaunch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataHome) }

    let logStream = try startFocusedValueLogStream()
    defer { terminate(logStream.process) }
    try await Task.sleep(for: .milliseconds(500))

    guard let appProcess = try launchUITestHost(dataHome: dataHome) else {
      return
    }
    defer { terminate(appProcess) }

    try await Task.sleep(for: .seconds(4))

    let warningLines = capturedFocusedValueWarnings(from: logStream)
    #expect(
      warningLines.isEmpty,
      """
      Launch emitted a SwiftUI FocusedValue warning:
      \(warningLines.joined(separator: "\n"))
      """
    )
  }

  @Test("Dashboard and scene focus publishers route through the deferred helper")
  func dashboardAndSceneFocusPublishersUseDeferredHelper() throws {
    let reviewsRouteSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardReviewsRouteView.swift"
    )
    let reviewsSearchSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardReviewsRouteView+ToolbarSearch.swift"
    )
    let policyCanvasSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift"
    )
    let auditTimelineSource = try harnessSourceFile(
      named: "App/HarnessMonitorAppSceneSupport+AuditTimeline.swift"
    )

    #expect(reviewsRouteSource.contains(".harnessFocusedSceneValue(\\.dashboardReviewsCommands"))
    #expect(!reviewsRouteSource.contains(".focusedSceneValue(\\.dashboardReviewsCommands"))
    #expect(
      reviewsSearchSource.contains(
        ".harnessFocusedSceneValue(\\.harnessSidebarSearchFocusAction"
      )
    )
    #expect(
      !reviewsSearchSource.contains(
        ".focusedSceneValue(\\.harnessSidebarSearchFocusAction"
      )
    )
    #expect(policyCanvasSource.contains(".harnessFocusedSceneValue("))
    #expect(policyCanvasSource.contains("\\.harnessPolicyCanvasCommandFocus"))
    #expect(policyCanvasSource.contains("sceneFocusEnabled ? commandFocus : nil"))
    #expect(!policyCanvasSource.contains(".focusedSceneValue(\\.harnessPolicyCanvasCommandFocus"))
    #expect(auditTimelineSource.contains(".harnessFocusedSceneValue("))
    #expect(!auditTimelineSource.contains(".focusedSceneValue("))
  }

  @Test("Policy canvas bootstraps before the initial remote policy load")
  func policyCanvasBootstrapsBeforeInitialRemotePolicyLoad() async {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    let dashboardUI = store.contentUI.dashboard
    let view = PolicyCanvasView(
      store: store,
      dashboardUI: dashboardUI,
      suppressesAutosave: true,
      suppressesSceneStorage: true
    )

    #expect(dashboardUI.taskBoardPolicyPipeline == nil)

    await view.loadPolicyPipeline()

    #expect(store.connectionState == .online)
    #expect(dashboardUI.taskBoardPolicyPipeline != nil)
    #expect(dashboardUI.taskBoardPolicyAudit != nil)
    #expect(client.readCallCount(.taskBoardPolicyPipeline) == 1)
    #expect(client.readCallCount(.taskBoardPolicyPipelineAudit) == 1)
  }

  @Test(
    "Startup with restoration bridge does not emit FocusedValue warnings",
    .disabled(
      """
      Currently fails due to a platform-level SwiftUI bug on macOS 26: \
      .inspector(isPresented:) emits "FocusedValue update tried to update \
      multiple times per frame" during initial window setup, even with a \
      constant-false binding and Text-only inspector content. \
      Minimal repro: Text("x").inspector(isPresented: .constant(false)) { Text("y") }. \
      Reenable once Apple fixes the platform bug or we move off .inspector.
      """
    )
  )
  func startupWithRestorationDoesNotEmitFocusedValueWarning() async throws {
    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "HarnessMonitorFocusedValueRestore-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataHome) }

    let logStream = try startFocusedValueLogStream()
    defer { terminate(logStream.process) }
    try await Task.sleep(for: .milliseconds(500))

    guard let appProcess = try launchUITestHost(dataHome: dataHome, includeUITestFlag: false) else {
      return
    }
    defer { terminate(appProcess) }

    try await Task.sleep(for: .seconds(4))

    let warningLines = capturedFocusedValueWarnings(from: logStream)
    #expect(
      warningLines.isEmpty,
      """
      Startup with restoration bridge emitted a SwiftUI FocusedValue warning:
      \(warningLines.joined(separator: "\n"))
      """
    )
  }

  private func launchUITestHost(
    dataHome: URL,
    includeUITestFlag: Bool = true
  ) throws -> Process? {
    let inherited = ProcessInfo.processInfo.environment
    let builtProductsDir = Bundle(for: StartupLogTestBundleToken.self)
      .bundleURL
      .deletingLastPathComponent()

    let executableURL =
      builtProductsDir
      .appendingPathComponent("Harness Monitor UI Testing.app", isDirectory: true)
      .appendingPathComponent("Contents/MacOS", isDirectory: true)
      .appendingPathComponent("Harness Monitor UI Testing", isDirectory: false)

    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      return nil
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    process.environment = launchEnvironment(
      inherited: inherited,
      dataHome: dataHome.path,
      includeUITestFlag: includeUITestFlag
    )
    try process.run()
    return process
  }

  private func launchEnvironment(
    inherited: [String: String],
    dataHome: String,
    includeUITestFlag: Bool = true
  ) -> [String: String] {
    var environment: [String: String] = [:]
    for key in [
      "HOME",
      "LOGNAME",
      "PATH",
      "SHELL",
      "TMPDIR",
      "USER",
      "__CF_USER_TEXT_ENCODING",
    ] {
      if let value = inherited[key] {
        environment[key] = value
      }
    }
    if includeUITestFlag {
      environment["HARNESS_MONITOR_UI_TESTS"] = "1"
    }
    environment["HARNESS_MONITOR_LAUNCH_MODE"] = "preview"
    environment["HARNESS_DAEMON_DATA_HOME"] = dataHome
    return environment
  }

  private func terminate(_ process: Process) {
    guard process.isRunning else {
      return
    }
    process.terminate()
    process.waitUntilExit()
  }

  private func startFocusedValueLogStream() throws -> LogStreamCapture {
    let logStream = Process()
    logStream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    logStream.arguments = [
      "stream",
      "--style", "compact",
      "--level", "debug",
      "--predicate",
      """
      (process == "Harness Monitor UI Testing" OR process == "Harness Monitor")
      AND eventMessage CONTAINS "FocusedValue update tried to update multiple times per frame"
      """,
    ]

    let stdout = Pipe()
    let stderr = Pipe()
    logStream.standardOutput = stdout
    logStream.standardError = stderr

    try logStream.run()
    return LogStreamCapture(process: logStream, stdout: stdout, stderr: stderr)
  }

  private func capturedFocusedValueWarnings(from logStream: LogStreamCapture) -> [String] {
    terminate(logStream.process)

    let output =
      String(
        bytes: logStream.stdout.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    let errorOutput =
      String(
        bytes: logStream.stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""

    return [output, errorOutput]
      .joined(separator: "\n")
      .split(separator: "\n")
      .map(String.init)
      .filter {
        $0.contains("[com.apple.SwiftUI:Invalid Configuration]")
          && $0.contains("FocusedValue update tried to update multiple times per frame")
      }
  }
}

private final class StartupLogTestBundleToken {}

private struct LogStreamCapture {
  let process: Process
  let stdout: Pipe
  let stderr: Pipe
}

private func previewableSourceFile(named name: String) throws -> String {
  try appSourceFile(
    root: "Sources/HarnessMonitorUIPreviewable",
    named: name
  )
}

private func harnessSourceFile(named name: String) throws -> String {
  try appSourceFile(
    root: "Sources/HarnessMonitor",
    named: name
  )
}

private func appSourceFile(
  root: String,
  named name: String
) throws -> String {
  let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let appRoot =
    testsDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let sourceURL =
    appRoot
    .appendingPathComponent(root)
    .appendingPathComponent(name)
  return try String(contentsOf: sourceURL, encoding: .utf8)
}
