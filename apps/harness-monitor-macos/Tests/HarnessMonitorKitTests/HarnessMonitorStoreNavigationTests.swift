import Foundation
import Observation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUI

@MainActor
@Suite("Harness Monitor store navigation history")
struct HarnessMonitorStoreNavigationTests {

  // MARK: - Direct selectSession path (proves store logic)

  @Test("Selecting session from dashboard pushes nil to back stack")
  func selectFromDashboard() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    #expect(store.navigationBackStack.count == 1)
    #expect(store.navigationBackStack.first == nil as String?)
  }

  @Test("Selecting two sessions populates the back stack")
  func selectTwoSessions() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("Navigate back restores previous session and populates forward stack")
  func navigateBack() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()

    #expect(store.selectedSessionID == "sess-a")
    #expect(store.navigationBackStack == [nil])
    #expect(store.navigationForwardStack == ["sess-b"] as [String?])
  }

  @Test("Navigate back to dashboard clears selection")
  func navigateBackToDashboard() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.navigateBack()

    #expect(store.selectedSessionID == nil)
    #expect(store.navigationBackStack.isEmpty)
    #expect(store.navigationForwardStack == ["sess-a"] as [String?])
  }

  @Test("Navigate forward after back restores forward session")
  func navigateForward() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()
    await store.navigateForward()

    #expect(store.selectedSessionID == "sess-b")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("New selection after back clears forward stack")
  func newSelectionClearsForward() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()
    await store.selectSession("sess-c")

    #expect(store.selectedSessionID == "sess-c")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("Sidebar flow: primeSessionSelection then selectSession records history")
  func sidebarPrimeThenSelect() async throws {
    let store = try await makeNavigationStore()

    store.primeSessionSelection("sess-a")
    await store.selectSession("sess-a")
    #expect(store.selectedSessionID == "sess-a")
    #expect(store.navigationBackStack.count == 1)

    store.primeSessionSelection("sess-b")
    await store.selectSession("sess-b")
    #expect(store.selectedSessionID == "sess-b")
    #expect(
      store.navigationBackStack.contains("sess-a"),
      "primeSessionSelection before selectSession must not prevent history recording"
    )
  }

  @Test("Observable tracking: back stack mutation is observable")
  func backStackMutationIsObservable() async throws {
    let store = try await makeNavigationStore()

    await confirmation("back stack change observed") { confirm in
      withObservationTracking {
        _ = store.navigationBackStack
      } onChange: {
        confirm()
      }

      await store.selectSession("sess-a")
    }

    #expect(!store.navigationBackStack.isEmpty)
  }

  @Test("Updating navigation availability keeps handler routing intact")
  func updatingNavigationAvailabilityKeepsHandlers() async {
    let backRecorder = ConfirmationRecorder()
    let forwardRecorder = ConfirmationRecorder()
    let state = WindowNavigationState()
    state.setHandlers(
      back: { await backRecorder.record() },
      forward: { await forwardRecorder.record() }
    )

    let updated = state.updating(canGoBack: true, canGoForward: true)

    #expect(updated.canGoBack)
    #expect(updated.canGoForward)

    await updated.navigateBack()
    await updated.navigateForward()

    #expect(await backRecorder.count == 1)
    #expect(await forwardRecorder.count == 1)
  }

  @Test("Updating with unchanged availability keeps the snapshot stable")
  func updatingWithSameAvailabilityKeepsSnapshotStable() async {
    let state = WindowNavigationState()
    let updated = state.updating(canGoBack: false, canGoForward: false)
    #expect(updated.canGoBack == state.canGoBack)
    #expect(updated.canGoForward == state.canGoForward)
  }

  @Test("Command routing scope persists until the active window is explicitly cleared")
  func commandRoutingScopePersistsUntilClear() async {
    let routingState = WindowCommandRoutingState()
    let mainWindow = NSObject()
    let agentWindow = NSObject()

    routingState.activate(scope: .main, windowID: ObjectIdentifier(mainWindow))
    #expect(routingState.activeScope == .main)

    routingState.activate(scope: .agentTui, windowID: ObjectIdentifier(agentWindow))
    #expect(routingState.activeScope == .agentTui)

    routingState.clear(windowID: ObjectIdentifier(mainWindow))
    #expect(
      routingState.activeScope == .agentTui,
      "Clearing a background window must not drop routing for the active window"
    )

    routingState.clear(windowID: ObjectIdentifier(agentWindow))
    #expect(routingState.activeScope == nil)
  }

  @Test("Launching the isolated host does not emit FocusedValue startup warnings")
  func launchDoesNotEmitFocusedValueWarning() async throws {
    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorFocusedValueLaunch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataHome) }

    let logStream = try startFocusedValueLogStream()
    defer { terminate(logStream.process) }
    try await Task.sleep(for: .milliseconds(500))

    let appProcess = try launchUITestHost(dataHome: dataHome)
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

    // Launch without HARNESS_MONITOR_UI_TESTS so the ContentSceneRestorationBridge
    // runs and enableStartupFocusParticipation() fires, exercising the real
    // inspector + sidebar focus hydration path.
    let appProcess = try launchUITestHost(dataHome: dataHome, includeUITestFlag: false)
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

  // MARK: - Fixtures

  private func makeNavigationStore() async throws -> HarnessMonitorStore {
    let summaries = ["sess-a", "sess-b", "sess-c"].map { id in
      makeSession(
        SessionFixture(
          sessionId: id,
          context: "Session \(id)",
          status: .active,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        )
      )
    }
    let details = Dictionary(
      uniqueKeysWithValues: summaries.map { summary in
        (
          summary.sessionId,
          makeSessionDetail(
            summary: summary,
            workerID: "worker-\(summary.sessionId)",
            workerName: "Worker \(summary.sessionId)"
          )
        )
      }
    )
    let client = RecordingHarnessClient(detail: try #require(details.values.first))
    client.configureSessions(summaries: summaries, detailsByID: details)
    return await makeBootstrappedStore(client: client)
  }

  private func launchUITestHost(
    dataHome: URL,
    includeUITestFlag: Bool = true
  ) throws -> Process {
    let inherited = ProcessInfo.processInfo.environment
    let builtProductsDir = Bundle(for: StartupLogTestBundleToken.self)
      .bundleURL
      .deletingLastPathComponent()

    let executableURL = builtProductsDir
      .appendingPathComponent("Harness Monitor UI Testing.app", isDirectory: true)
      .appendingPathComponent("Contents/MacOS", isDirectory: true)
      .appendingPathComponent("Harness Monitor UI Testing", isDirectory: false)

    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw StartupLogTestError("UI-test host is not executable at \(executableURL.path)")
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

    let output = String(
      decoding: logStream.stdout.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    let errorOutput = String(
      decoding: logStream.stderr.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )

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

private struct StartupLogTestError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

private final class StartupLogTestBundleToken {}

private actor ConfirmationRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private struct LogStreamCapture {
  let process: Process
  let stdout: Pipe
  let stderr: Pipe
}
