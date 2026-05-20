import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorPerfTests: HarnessMonitorUITestCase {
  private static let previewSessionID = Accessibility.previewSessionID

  func testOpenRecentWindowScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "open-recent-window")
    let dashboardRoot = element(in: launched, identifier: Accessibility.dashboardWindowRoot)
    let dashboardScrollView = element(in: launched, identifier: Accessibility.dashboardScrollView)
    let sessionRow = element(
      in: launched,
      identifier: Accessibility.sessionRow(Self.previewSessionID)
    )
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)

    waitForScenarioCompletion(app: launched, scenario: "open-recent-window")

    XCTAssertTrue(dashboardRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(dashboardScrollView.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(sessionWindow.exists)

    launched.terminate()
  }

  func testLaunchForPerfSeedsObservabilityConfigIntoIsolatedDataHome() throws {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)

    XCTAssertNotNil(
      configureIsolatedDataHome(for: app, purpose: "perf-observability-config")
    )

    let isolatedRoot = try XCTUnwrap(app.launchEnvironment[Self.daemonDataHomeKey])
    let configURL = URL(fileURLWithPath: isolatedRoot, isDirectory: true)
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("observability", isDirectory: true)
      .appendingPathComponent("config.json")

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: configURL.path),
      "Expected isolated perf runs to seed an observability config"
    )
    let configBody = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssertTrue(configBody.contains("\"enabled\": true"))
    XCTAssertTrue(configBody.contains("\"grpc_endpoint\": \"http://127.0.0.1:4317\""))
  }

  func testOpenSessionWindowScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "open-session-window")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)

    waitForScenarioCompletion(app: launched, scenario: "open-session-window")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))

    launched.terminate()
  }

  func testPolicyCanvasScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "policy-canvas")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let canvasRoot = element(in: launched, identifier: Accessibility.policyCanvasRoot)
    let toolRail = element(in: launched, identifier: Accessibility.policyCanvasToolRail)

    waitForScenarioCompletion(app: launched, scenario: "policy-canvas")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(canvasRoot, timeout: Self.uiTimeout),
      "Policy Canvas perf scenario did not render the policy canvas surface"
    )
    XCTAssertTrue(
      waitForElement(toolRail, timeout: Self.actionTimeout),
      "Policy Canvas perf scenario did not render the policy canvas tool rail"
    )

    launched.terminate()
  }

  func testAgentDetailFormScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "agent-detail-form")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let agentDetail = element(in: launched, identifier: Accessibility.agentDetailScrollView)

    waitForScenarioCompletion(app: launched, scenario: "agent-detail-form")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(agentDetail, timeout: Self.uiTimeout),
      "Agent detail perf scenario did not render the current agent detail pane"
    )
    XCTAssertTrue(
      launched.staticTexts["Codex Worker"].firstMatch.waitForExistence(timeout: Self.actionTimeout)
    )

    launched.terminate()
  }

  func testDecisionDetailFormScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "decision-detail-form")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let decisionDetail = element(in: launched, identifier: Accessibility.decisionDetailScrollView)
    let acpPanel = element(in: launched, identifier: Accessibility.decisionAcpPanel)

    waitForScenarioCompletion(app: launched, scenario: "decision-detail-form")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(decisionDetail, timeout: Self.uiTimeout),
      "Decision detail perf scenario did not render the current decision detail pane"
    )
    XCTAssertTrue(
      waitForElement(acpPanel, timeout: Self.actionTimeout),
      "Decision detail perf scenario did not render the ACP decision form"
    )

    launched.terminate()
  }

  func testTaskDetailFormScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "task-detail-form")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let taskDetail = element(in: launched, identifier: Accessibility.sessionTaskDetailScrollView)

    waitForScenarioCompletion(app: launched, scenario: "task-detail-form")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(taskDetail, timeout: Self.uiTimeout),
      "Task detail perf scenario did not render the current task detail pane"
    )
    XCTAssertTrue(
      launched.buttons["Task Actions"].firstMatch.waitForExistence(timeout: Self.actionTimeout)
    )

    launched.terminate()
  }

  func testSessionSearchFullScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "session-search-full")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let searchField = mainWindow(in: launched).searchFields.firstMatch
    let agentDetail = element(in: launched, identifier: Accessibility.agentDetailScrollView)

    waitForScenarioCompletion(app: launched, scenario: "session-search-full")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(searchField, timeout: Self.uiTimeout),
      "Session search perf scenario should expose the native toolbar search field"
    )
    exerciseSessionSearch(in: launched, query: "worker")
    XCTAssertTrue(
      launched.staticTexts["Codex Worker"].firstMatch.waitForExistence(timeout: Self.actionTimeout)
    )
    acceptFirstNativeSearchSuggestion(in: launched)
    XCTAssertTrue(
      waitForElement(agentDetail, timeout: Self.actionTimeout),
      "Keyboard acceptance of the native search suggestion should route to agent detail"
    )

    launched.terminate()
  }

  func testSidebarToggleRichDetailScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "sidebar-toggle-rich-detail")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let timelineFilterBar = element(
      in: launched,
      identifier: Accessibility.sessionTimelineFilterBar
    )

    waitForScenarioCompletion(app: launched, scenario: "sidebar-toggle-rich-detail")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(timelineFilterBar, timeout: Self.uiTimeout),
      "Sidebar toggle perf scenario should finish on the timeline surface"
    )

    launched.terminate()
  }

  func testTimelineFilterFormScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "timeline-filter-form")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let filterBar = element(in: launched, identifier: Accessibility.sessionTimelineFilterBar)
    let filterState = element(in: launched, identifier: Accessibility.sessionTimelineFilterState)

    waitForScenarioCompletion(app: launched, scenario: "timeline-filter-form")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(waitForElement(filterBar, timeout: Self.uiTimeout))
    XCTAssertTrue(waitForElement(filterState, timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let text = self.markerText(filterState)
        return text.contains("query=worker")
          && text.contains("agents=worker-codex")
          && text.contains("tasks=task-ui")
      },
      "Timeline filter perf scenario did not seed the expected active filters"
    )

    launched.terminate()
  }

  func testPermissionModalScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "permission-modal")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let decisionID = "acp-permission:preview-acp-permission-1"
    let decisionRow = element(in: launched, identifier: Accessibility.decisionRow(decisionID))
    let legacyModal = element(in: launched, identifier: Accessibility.acpPermissionModal)

    waitForScenarioCompletion(app: launched, scenario: "permission-modal")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.uiTimeout),
      "Permission perf scenario did not surface the routed ACP decision row"
    )
    XCTAssertFalse(legacyModal.exists)

    launched.terminate()
  }

  func testTaskBoardSettingsScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "task-board-settings")
    let settingsRoot = element(in: launched, identifier: Accessibility.settingsRoot)
    let saveButton = element(in: launched, identifier: Accessibility.settingsTaskBoardSaveButton)
    let ownerField = element(in: launched, identifier: Accessibility.settingsTaskBoardOwnerField)
    let status = element(in: launched, identifier: Accessibility.settingsTaskBoardStatus)

    waitForScenarioCompletion(app: launched, scenario: "task-board-settings")

    XCTAssertTrue(waitForElement(settingsRoot, timeout: Self.uiTimeout))
    XCTAssertTrue(waitForElement(saveButton, timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitForElement(ownerField, timeout: Self.actionTimeout),
      "Task Board settings perf scenario should load editable Task Board fields"
    )
    XCTAssertFalse(status.exists, "Task Board settings perf scenario should not settle on an error")

    launched.terminate()
  }

}
