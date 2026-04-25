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
  }

  let app: XCUIApplication
  let sessionID: String

  private let testCase: HarnessMonitorUITestCase
  private let stateRootURL: URL
  private let dataHomeURL: URL
  private let daemonLogPath: String
  private let syncDirURL: URL

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
    app.launch()
    XCTAssertTrue(
      testCase.waitUntil(timeout: 25) {
        if self.app.state != .runningForeground {
          self.app.activate()
        }
        return self.app.state == .runningForeground || self.testCase.mainWindow(in: self.app).exists
      },
      diagnosticsSummary()
    )
    XCTAssertTrue(
      testCase.waitUntil(timeout: 25) {
        let window = self.testCase.mainWindow(in: self.app)
        return window.exists && window.frame.width > 0 && window.frame.height > 0
      },
      diagnosticsSummary()
    )
  }

  func waitForReady(_ act: String, timeout: TimeInterval = 120) throws -> [String: String] {
    let url = syncDirURL.appendingPathComponent("\(act).ready")
    XCTAssertTrue(
      testCase.waitUntil(timeout: timeout) {
        FileManager.default.fileExists(atPath: url.path)
      },
      "Timed out waiting for \(act).ready\n\(diagnosticsSummary())"
    )
    return try Self.readKeyValueMarker(url)
  }

  func ack(_ act: String) throws {
    let url = syncDirURL.appendingPathComponent("\(act).ack")
    try "ack\n".write(to: url, atomically: true, encoding: .utf8)
  }

  func openSession(_ sessionID: String) {
    let identifier = Accessibility.sessionRow(sessionID)
    let row = testCase.sessionTrigger(in: app, identifier: identifier)
    XCTAssertTrue(
      testCase.waitForElement(row, timeout: 25),
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
      XCTAssertTrue(
        selected,
        """
        Swarm session row never reported selection.
        rowValue=\(String(describing: row.value))
        toolbarState=\(toolbarState.label)
        \(diagnosticsSummary())
        """
      )
    }
  }

  func selectTask(_ taskID: String) {
    let identifier = Accessibility.sessionTaskCard(taskID)
    let task = testCase.element(in: app, identifier: identifier)
    XCTAssertTrue(
      testCase.waitForElement(task, timeout: 15),
      "Expected swarm task card \(taskID)\n\(diagnosticsSummary())"
    )
    XCTAssertTrue(
      scrollElementIntoView(task),
      """
      Expected swarm task card \(taskID) to become hittable.
      taskFrame=\(task.frame)
      scrollFrame=\(scrollTarget(for: task).frame)
      \(diagnosticsSummary())
      """
    )
    testCase.tapElement(in: app, identifier: identifier)
  }

  func expectIdentifier(_ identifier: String, timeout: TimeInterval = 15) {
    let element = testCase.element(in: app, identifier: identifier)
    XCTAssertTrue(
      testCase.waitForElement(element, timeout: timeout),
      "Expected identifier \(identifier)\n\(diagnosticsSummary())"
    )
  }

  func expectIdentifier(_ identifier: String, labelContains expectedText: String) {
    let element = testCase.element(in: app, identifier: identifier)
    XCTAssertTrue(
      testCase.waitUntil(timeout: 15) {
        element.exists && element.label.contains(expectedText)
      },
      """
      Expected identifier \(identifier) label to contain \(expectedText).
      actualLabel=\(element.label)
      \(diagnosticsSummary())
      """
    )
  }

  func expectAnyIdentifier(_ identifiers: [String], timeout: TimeInterval = 15) {
    XCTAssertTrue(
      testCase.waitUntil(timeout: timeout) {
        identifiers.contains { self.testCase.element(in: self.app, identifier: $0).exists }
      },
      "Expected one of \(identifiers.joined(separator: ", "))\n\(diagnosticsSummary())"
    )
  }

  func diagnosticsSummary() -> String {
    [
      "stateRoot=\(stateRootURL.path)",
      "dataHome=\(dataHomeURL.path)",
      "sessionID=\(sessionID)",
      "daemonLog=\(daemonLogPath)",
      "syncDir=\(syncDirURL.path)",
    ].joined(separator: "\n")
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

  private func scrollElementIntoView(
    _ element: XCUIElement,
    timeout: TimeInterval = 8
  ) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }
      if element.exists && element.isHittable {
        return true
      }

      scrollToward(element)
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.15))
    }
    return element.exists && element.isHittable
  }

  private func scrollToward(_ element: XCUIElement) {
    let target = scrollTarget(for: element)
    let window = testCase.mainWindow(in: app)
    if element.exists,
      !element.frame.isEmpty,
      !window.frame.isEmpty,
      element.frame.minY < window.frame.minY + 72
    {
      testCase.dragDown(in: app, element: target, distanceRatio: 0.18)
      return
    }

    testCase.dragUp(in: app, element: target, distanceRatio: 0.18)
  }

  private func scrollTarget(for element: XCUIElement) -> XCUIElement {
    let window = testCase.mainWindow(in: app)
    if let scrollView = matchingScrollTarget(in: window.scrollViews, for: element) {
      return scrollView
    }
    if let scrollView = matchingScrollTarget(in: app.scrollViews, for: element) {
      return scrollView
    }

    let windowScrollView = window.scrollViews.firstMatch
    if windowScrollView.exists {
      return windowScrollView
    }

    let appScrollView = app.scrollViews.firstMatch
    return appScrollView.exists ? appScrollView : window
  }

  private func matchingScrollTarget(
    in query: XCUIElementQuery,
    for element: XCUIElement
  ) -> XCUIElement? {
    guard element.exists, !element.frame.isEmpty else { return nil }

    let elementFrame = element.frame
    let elementMidX = elementFrame.midX
    let searchCount = min(query.count, 12)
    var bestOverlap: CGFloat = 0
    var bestMatch: XCUIElement?

    for index in 0..<searchCount {
      let candidate = query.element(boundBy: index)
      guard candidate.exists, !candidate.frame.isEmpty else { continue }

      let candidateFrame = candidate.frame
      if candidateFrame.minX <= elementMidX, elementMidX <= candidateFrame.maxX {
        return candidate
      }

      let horizontalOverlap =
        min(candidateFrame.maxX, elementFrame.maxX) - max(candidateFrame.minX, elementFrame.minX)
      if horizontalOverlap > bestOverlap {
        bestOverlap = horizontalOverlap
        bestMatch = candidate
      }
    }

    return bestMatch
  }
}

@MainActor
final class SwarmRunner {
  private let fixture: SwarmFixture

  init(fixture: SwarmFixture) {
    self.fixture = fixture
  }

  func act1() throws {
    let marker = try fixture.waitForReady("act1")
    fixture.openSession(marker["session_id"] ?? fixture.sessionID)
    try fixture.ack("act1")
  }

  func act2() throws {
    let marker = try fixture.waitForReady("act2")
    if let agentID = marker["worker_codex_id"] {
      fixture.expectIdentifier(Accessibility.sessionAgentListState, labelContains: agentID)
    }
    if let agentID = marker["worker_claude_id"] {
      fixture.expectIdentifier(Accessibility.sessionAgentListState, labelContains: agentID)
    }
    try fixture.ack("act2")
  }

  func act3() throws {
    let marker = try fixture.waitForReady("act3")
    if let taskID = marker["task_review_id"] {
      fixture.expectIdentifier(Accessibility.sessionTaskCard(taskID))
    }
    try fixture.ack("act3")
  }

  func act4() throws {
    let marker = try fixture.waitForReady("act4")
    if let taskID = marker["task_review_id"] {
      fixture.selectTask(taskID)
    }
    try fixture.ack("act4")
  }

  func act5() throws {
    let marker = try fixture.waitForReady("act5")
    fixture.expectIdentifier(
      Accessibility.heuristicIssueCard(marker["heuristic_code"] ?? "python_traceback_output"))
    try fixture.ack("act5")
  }

  func act6() throws {
    _ = try fixture.waitForReady("act6")
    try fixture.ack("act6")
  }

  func act7() throws {
    _ = try fixture.waitForReady("act7")
    try fixture.ack("act7")
  }

  func act8() throws {
    let marker = try fixture.waitForReady("act8")
    if let taskID = marker["task_review_id"] {
      fixture.selectTask(taskID)
      fixture.expectIdentifier(Accessibility.awaitingReviewBadge(taskID))
    }
    try fixture.ack("act8")
  }

  func act9() throws {
    let marker = try fixture.waitForReady("act9")
    if let taskID = marker["task_review_id"] {
      fixture.expectAnyIdentifier([
        Accessibility.reviewerClaimBadge(taskID, runtime: marker["reviewer_runtime"] ?? "claude"),
        Accessibility.reviewerQuorumIndicator(taskID),
      ])
    }
    try fixture.ack("act9")
  }

  func act10() throws {
    let marker = try fixture.waitForReady("act10")
    if let workerID = marker["worker_claude_id"] {
      fixture.expectAnyIdentifier([
        Accessibility.autoSpawnedBadge(workerID),
        Accessibility.sessionAgentCard(workerID),
      ])
    }
    try fixture.ack("act10")
  }

  func act11() throws {
    _ = try fixture.waitForReady("act11")
    fixture.expectAnyIdentifier([
      Accessibility.workerRefusalToast,
      Accessibility.taskInspectorCard,
    ])
    try fixture.ack("act11")
  }

  func act12() throws {
    let marker = try fixture.waitForReady("act12")
    if let taskID = marker["task_arbitration_id"] {
      fixture.selectTask(taskID)
      fixture.expectAnyIdentifier([
        Accessibility.partialAgreementChip(marker["point_id"] ?? "p1"),
        Accessibility.reviewPointChip(marker["point_id"] ?? "p1"),
        Accessibility.roundCounter(taskID),
      ])
    }
    try fixture.ack("act12")
  }

  func act13() throws {
    let marker = try fixture.waitForReady("act13")
    if let taskID = marker["task_arbitration_id"] {
      fixture.expectAnyIdentifier([
        Accessibility.arbitrationBanner(taskID),
        Accessibility.roundCounter(taskID),
      ])
    }
    try fixture.ack("act13")
  }

  func act14() throws {
    _ = try fixture.waitForReady("act14")
    fixture.expectAnyIdentifier([
      Accessibility.signalCollisionToast,
      Accessibility.taskInspectorCard,
    ])
    try fixture.ack("act14")
  }

  func act15() throws {
    _ = try fixture.waitForReady("act15")
    fixture.expectAnyIdentifier([
      Accessibility.observeScanButton,
      Accessibility.observeDoctorButton,
      Accessibility.observeSessionButton,
      Accessibility.observeSummaryButton,
    ])
    try fixture.ack("act15")
  }

  func act16() throws {
    _ = try fixture.waitForReady("act16")
    fixture.expectIdentifier(Accessibility.sessionStatusCorner, timeout: 20)
    try fixture.ack("act16")
  }
}
