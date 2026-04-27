import Foundation
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SwarmFixture {
  private enum EnvironmentKey {
    static let enableSwarmE2E = "HARNESS_MONITOR_ENABLE_SWARM_E2E"
    static let stateRoot = "HARNESS_MONITOR_SWARM_E2E_STATE_ROOT"
    static let dataHome = "HARNESS_MONITOR_SWARM_E2E_DATA_HOME"
    static let daemonLog = "HARNESS_MONITOR_SWARM_E2E_DAEMON_LOG"
    static let sessionID = "HARNESS_MONITOR_SWARM_E2E_SESSION_ID"
    static let syncDir = "HARNESS_MONITOR_SWARM_E2E_SYNC_DIR"
    static let stepTimeouts = "HARNESS_MONITOR_SWARM_E2E_STEP_TIMEOUTS"
  }

  let app: XCUIApplication
  let sessionID: String

  let testCase: HarnessMonitorUITestCase
  let stateRootURL: URL
  let dataHomeURL: URL
  let daemonLogPath: String
  let syncDirURL: URL
  let stepTimeouts: [String: TimeInterval]

  init(testCase: HarnessMonitorUITestCase) throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment[EnvironmentKey.enableSwarmE2E] == "1" else {
      throw XCTSkip(
        """
        Swarm full-flow e2e is explicit-only. \
        Run mise run monitor:macos:test:swarm-e2e.
        """
      )
    }

    self.testCase = testCase
    self.stateRootURL = URL(
      fileURLWithPath: try Self.required(EnvironmentKey.stateRoot, from: environment),
      isDirectory: true
    )
    self.dataHomeURL = URL(
      fileURLWithPath: try Self.required(EnvironmentKey.dataHome, from: environment),
      isDirectory: true
    )
    self.daemonLogPath = try Self.required(EnvironmentKey.daemonLog, from: environment)
    self.sessionID = try Self.required(EnvironmentKey.sessionID, from: environment)
    self.syncDirURL = URL(
      fileURLWithPath: try Self.required(EnvironmentKey.syncDir, from: environment),
      isDirectory: true
    )
    self.stepTimeouts = Self.decodeStepTimeouts(from: environment[EnvironmentKey.stepTimeouts])
    self.app = XCUIApplication(
      bundleIdentifier: HarnessMonitorUITestCase.uiTestHostBundleIdentifier)
  }

  func launch() {
    testCase.terminateIfRunning(app)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment = [
      "HARNESS_DAEMON_DATA_HOME": dataHomeURL.path,
      "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
      "HARNESS_MONITOR_LAUNCH_MODE": "live",
      "HARNESS_MONITOR_RESET_BACKGROUND_RECENTS": "1",
      "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "820",
      "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "1280",
      "HARNESS_MONITOR_UI_TESTS": "1",
    ]
    trace(
      "launch.start",
      details: [
        "session_id": sessionID,
        "data_home": dataHomeURL.path,
        "daemon_log": daemonLogPath,
        "sync_dir": syncDirURL.path,
      ]
    )
    guard testCase.armRecordingStartIfConfigured(context: diagnosticsSummary()) else {
      return
    }
    app.launch()
    trace("launch.app-launched", app: app)
    let foregroundReady = testCase.waitUntil(timeout: 25) {
      if self.app.state != .runningForeground {
        self.app.activate()
      }
      return self.app.state == .runningForeground || self.testCase.mainWindow(in: self.app).exists
    }
    if !foregroundReady {
      trace(
        "launch.foreground.timeout",
        app: app,
        details: [
          "session_id": sessionID,
          "sync_dir": syncDirURL.path,
        ]
      )
    }
    XCTAssertTrue(foregroundReady, diagnosticsSummary())
    guard testCase.provideRecordingPidIfConfigured(for: app, context: diagnosticsSummary()) else {
      return
    }
    guard testCase.waitForRecordingStartIfConfigured(context: diagnosticsSummary()) else {
      return
    }
    trace("launch.recording-started", app: app)
    let windowReady = testCase.waitUntil(timeout: 25) {
      let window = self.testCase.mainWindow(in: self.app)
      return window.exists && window.frame.width > 0 && window.frame.height > 0
    }
    if !windowReady {
      trace(
        "launch.window.timeout",
        app: app,
        details: [
          "session_id": sessionID,
          "sync_dir": syncDirURL.path,
        ]
      )
    }
    XCTAssertTrue(windowReady, diagnosticsSummary())
    if windowReady {
      trace("launch.window-ready", app: app)
    }
  }

  func waitForReady(_ act: String, timeout: TimeInterval? = nil) throws -> [String: String] {
    let url = syncDirURL.appendingPathComponent("\(act).ready")
    let resolvedTimeout = timeout ?? stepTimeouts[act] ?? stepTimeouts["default"] ?? 30
    trace(
      "act.ready.wait.begin",
      details: [
        "act": act,
        "timeout_seconds": String(resolvedTimeout),
        "marker": url.path,
      ]
    )
    let ready = testCase.waitUntil(timeout: resolvedTimeout) {
      FileManager.default.fileExists(atPath: url.path)
    }
    if !ready {
      trace(
        "act.ready.wait.timeout",
        details: [
          "act": act,
          "marker": url.path,
          "timeout_seconds": String(resolvedTimeout),
        ]
      )
    }
    XCTAssertTrue(
      ready,
      "Timed out waiting for \(act).ready after \(Int(resolvedTimeout))s\n\(diagnosticsSummary())"
    )
    if ready {
      trace(
        "act.ready.wait.success",
        details: [
          "act": act,
          "marker": url.path,
        ]
      )
    }
    return try Self.readKeyValueMarker(url)
  }

  func ack(_ act: String) throws {
    let url = syncDirURL.appendingPathComponent("\(act).ack")
    try "ack\n".write(to: url, atomically: true, encoding: .utf8)
    trace("act.ack.write", details: ["act": act, "marker": url.path])
  }

  func captureCheckpoint(_ name: String) {
    trace("checkpoint.capture", app: app, details: ["name": name])
    testCase.recordDiagnosticsSnapshot(in: app, named: "swarm-\(name)")
  }

  func dismissTaskActionsSheetIfPresent() {
    guard taskActionsSheetIsPresented() else {
      return
    }
    trace("task-actions.dismiss.begin", app: app)
    app.typeKey(.escape, modifierFlags: [])
    let dismissed = testCase.waitUntil(timeout: 5) { !self.taskActionsSheetIsPresented() }
    if dismissed {
      trace("task-actions.dismiss.success", app: app)
    } else {
      trace("task-actions.dismiss.timeout", app: app)
    }
    XCTAssertTrue(
      dismissed,
      "Expected task actions sheet to dismiss\n\(diagnosticsSummary())"
    )
  }

  func openAgentsWindow() {
    dismissTaskActionsSheetIfPresent()
    let identifier = Accessibility.agentsButton
    trace("open-agents.begin", app: app, details: ["identifier": identifier])
    testCase.tapElement(in: app, identifier: identifier)
    let opened = testCase.waitUntil(timeout: 10) {
      self.testCase.element(in: self.app, identifier: Accessibility.agentTuiLaunchPane).exists
        || self.testCase.element(in: self.app, identifier: Accessibility.agentTuiSessionPane)
          .exists
    }
    if opened {
      trace("open-agents.success", app: app)
    } else {
      trace("open-agents.timeout", app: app)
    }
    XCTAssertTrue(
      opened,
      "Expected Agents window to appear\n\(diagnosticsSummary())"
    )
  }

  func closeAgentsWindow() {
    let agentsWindow = testCase.element(in: app, identifier: Accessibility.agentsWindow)
    let agentsState = testCase.element(in: app, identifier: Accessibility.agentTuiState)
    let launchPane = testCase.element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let sessionPane = testCase.element(in: app, identifier: Accessibility.agentTuiSessionPane)
    guard agentsWindow.exists || agentsState.exists || launchPane.exists || sessionPane.exists else {
      return
    }
    trace("close-agents.begin", app: app)
    app.typeKey("w", modifierFlags: .command)
    let closed = testCase.waitUntil(timeout: 10) {
      !agentsWindow.exists && !agentsState.exists && !launchPane.exists && !sessionPane.exists
    }
    if closed {
      trace("close-agents.success", app: app)
    } else {
      trace("close-agents.timeout", app: app)
    }
    XCTAssertTrue(
      closed,
      "Expected Agents window to close\n\(diagnosticsSummary())"
    )
  }

  func selectAgentsTask(_ taskID: String) {
    let tabID = Accessibility.agentsTaskTab(taskID)
    let selectionID = Accessibility.agentsTaskSelection(taskID)
    let taskTab = testCase.element(in: app, identifier: tabID)
    let sidebar = agentsSidebarScrollView()
    trace(
      "select-agents-task.begin",
      app: app,
      details: [
        "task_id": taskID,
        "tab_identifier": tabID,
        "selection_identifier": selectionID,
      ]
    )
    let sidebarReady = testCase.waitUntil(timeout: 5) {
      if self.app.state != .runningForeground {
        self.app.activate()
      }
      return sidebar.exists && !sidebar.frame.isEmpty && sidebar.scrollBars.firstMatch.exists
    }
    XCTAssertTrue(
      sidebarReady,
      "Expected Agents sidebar scroll view to be available\n\(diagnosticsSummary())"
    )

    let taskVisible = testCase.waitUntil(timeout: 12) {
      if self.app.state != .runningForeground {
        self.app.activate()
      }
      if self.elementIsVisible(taskTab, in: sidebar) {
        return true
      }
      sidebar.scroll(byDeltaX: 0, deltaY: -max(240, sidebar.frame.height * 0.9))
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
      return false
    }
    if taskVisible {
      trace("select-agents-task.visible", app: app, details: ["task_id": taskID])
    } else {
      trace("select-agents-task.timeout", app: app, details: ["task_id": taskID])
    }
    XCTAssertTrue(
      taskVisible,
      """
      Expected Agents task tab \(taskID) to become visible inside the Agents sidebar.
      agentsWindowState=\(currentAgentsWindowStateLabel())
      \(diagnosticsSummary())
      """
    )
    testCase.tapElement(in: app, identifier: tabID)
    let selected = testCase.waitUntil(timeout: 5) {
      self.currentAgentsWindowStateLabel().contains("selection=task:\(taskID)")
    }
    XCTAssertTrue(
      selected,
      """
      Expected Agents task tab \(taskID) to become selected after tap.
      agentsWindowState=\(currentAgentsWindowStateLabel())
      \(diagnosticsSummary())
      """
    )
    expectIdentifier(selectionID)
  }

  private func currentAgentsSidebarSelectionIdentifier() -> String? {
    let label = currentAgentsWindowStateLabel()
    if label.contains("selection=create") {
      return Accessibility.agentTuiCreateTab
    }
    if let agentID = selectionValue(in: label, prefix: "selection=agent:") {
      return Accessibility.agentTuiExternalTab(agentID)
    }
    if let taskID = selectionValue(in: label, prefix: "selection=task:") {
      return Accessibility.agentsTaskTab(taskID)
    }
    return nil
  }

  private func currentAgentsWindowStateLabel() -> String {
    let identifiers = [Accessibility.agentTuiState, Accessibility.agentsWindow]
    for identifier in identifiers {
      let matches = app.descendants(matching: .any).matching(identifier: identifier)
      let searchCount = min(matches.count, 8)
      for index in 0..<searchCount {
        let candidate = matches.element(boundBy: index)
        guard candidate.exists, candidate.label.isEmpty == false else {
          continue
        }
        return candidate.label
      }
    }
    return ""
  }

  private func selectionValue(in label: String, prefix: String) -> String? {
    guard let start = label.range(of: prefix)?.upperBound else {
      return nil
    }
    let tail = label[start...]
    return tail.split(separator: ",", maxSplits: 1).first.map(String.init)
  }

  private func agentsSidebarScrollView() -> XCUIElement {
    let createRow = testCase.element(in: app, identifier: Accessibility.agentTuiCreateTab)
    let launchPane = testCase.element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let anchor = createRow.exists ? createRow : launchPane
    let agentsWindow = testCase.window(in: app, containing: anchor)
    return agentsWindow.scrollViews.element(boundBy: 0)
  }

  private func elementIsVisible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
    guard
      element.exists,
      !element.frame.isEmpty,
      container.exists,
      !container.frame.isEmpty
    else {
      return false
    }

    let visibleFrame = element.frame.intersection(container.frame)
    return !visibleFrame.isNull && !visibleFrame.isEmpty
  }

  func openSession(_ sessionID: String) {
    let identifier = Accessibility.sessionRow(sessionID)
    let row = testCase.sessionTrigger(in: app, identifier: identifier)
    trace(
      "open-session.begin",
      app: app,
      details: [
        "session_id": sessionID,
        "identifier": identifier,
      ]
    )
    let rowExists = testCase.waitForElement(row, timeout: 25)
    if !rowExists {
      trace(
        "open-session.row-timeout",
        app: app,
        details: [
          "session_id": sessionID,
          "identifier": identifier,
        ]
      )
    }
    XCTAssertTrue(
      rowExists,
      "Expected swarm session row \(identifier)\n\(diagnosticsSummary())"
    )

    let toolbarState = testCase.element(in: app, identifier: Accessibility.toolbarChromeState)
    let sessionIsOpen = {
      self.testCase.sessionRowIsSelected(row)
        || toolbarState.label.contains("windowTitle=Cockpit")
    }
    let attemptSelection = {
      self.testCase.tapSession(in: self.app, identifier: identifier)
      return self.testCase.waitUntil(timeout: 1.5) {
        sessionIsOpen()
      }
    }

    if !sessionIsOpen() {
      let selected = attemptSelection() || attemptSelection() || attemptSelection()
      trace(
        selected ? "open-session.selected" : "open-session.failed",
        app: app,
        details: [
          "session_id": sessionID,
          "identifier": identifier,
          "row_value": row.value.map { String(describing: $0) } ?? "nil",
          "toolbar_state": toolbarState.label,
          "selected": String(selected),
        ]
      )
      XCTAssertTrue(
        selected,
        """
        Swarm session row never reported selection.
        rowValue=\(String(describing: row.value))
        toolbarState=\(toolbarState.label)
        \(diagnosticsSummary())
        """
      )
    } else {
      trace(
        "open-session.already-selected",
        app: app,
        details: [
          "session_id": sessionID,
          "identifier": identifier,
          "row_value": row.value.map { String(describing: $0) } ?? "nil",
          "toolbar_state": toolbarState.label,
        ]
      )
    }
  }

  func selectTask(_ taskID: String) {
    let identifier = Accessibility.sessionTaskCard(taskID)
    let task = testCase.element(in: app, identifier: identifier)
    trace(
      "select-task.begin",
      app: app,
      details: [
        "task_id": taskID,
        "identifier": identifier,
        "task_exists": String(task.exists),
      ]
    )
    if taskActionsSheetIsPresented() {
      trace("select-task.sheet-presented", app: app, details: ["task_id": taskID])
      return
    }
    expectIdentifier(Accessibility.sessionTaskListState, labelContains: taskID)
    if taskActionsSheetIsPresented() {
      trace(
        "select-task.sheet-presented-after-list-check",
        app: app,
        details: ["task_id": taskID]
      )
      return
    }
    let target = sessionTaskScrollView(for: task)
    trace(
      "select-task.scroll-target",
      app: app,
      details: [
        "task_id": taskID,
        "identifier": identifier,
        "scroll_frame": frameSummary(target.frame),
      ]
    )
    let taskVisible = scrollSessionTaskIntoView(task)
    if !taskVisible {
      trace(
        "select-task.scroll-timeout",
        app: app,
        details: [
          "task_id": taskID,
          "identifier": identifier,
          "task_frame": frameSummary(task.frame),
          "scroll_frame": frameSummary(target.frame),
        ]
      )
    }
    XCTAssertTrue(
      taskVisible,
      """
      Expected swarm task card \(taskID) to become hittable.
      taskFrame=\(task.frame)
      scrollFrame=\(target.frame)
      \(diagnosticsSummary())
      """
    )
    if taskVisible {
      trace(
        "select-task.visible",
        app: app,
        details: [
          "task_id": taskID,
          "identifier": identifier,
          "task_frame": frameSummary(task.frame),
          "scroll_frame": frameSummary(target.frame),
        ]
      )
    }
    testCase.tapElement(in: app, identifier: identifier)
    XCTAssertTrue(
      testCase.waitUntil(timeout: 5) { self.taskActionsSheetIsPresented() },
      """
      Expected swarm task \(taskID) to open the task actions sheet.
      taskLabel=\(task.label)
      \(diagnosticsSummary())
      """
    )
    trace("select-task.sheet-opened", app: app, details: ["task_id": taskID])
  }

  private static func required(
    _ key: String,
    from environment: [String: String]
  ) throws -> String {
    guard
      let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      rawValue.isEmpty == false
    else {
      throw NSError(
        domain: "HarnessMonitorSwarmE2E",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Missing swarm e2e environment variable: \(key)"
        ]
      )
    }
    return rawValue
  }

  private static func readKeyValueMarker(_ url: URL) throws -> [String: String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      values[String(parts[0])] = String(parts[1])
    }
    return values
  }

  private static func decodeStepTimeouts(from rawValue: String?) -> [String: TimeInterval] {
    guard
      let rawValue,
      let data = rawValue.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }

    var decoded: [String: TimeInterval] = [:]
    for (key, value) in object {
      if let number = value as? NSNumber {
        decoded[key] = number.doubleValue
      }
    }
    return decoded
  }

}
