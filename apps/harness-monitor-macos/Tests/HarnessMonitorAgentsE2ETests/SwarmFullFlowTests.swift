import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// Single XCUITest that drives the full swarm review flow through the Monitor
/// UI against the state the companion orchestrator script seeded into a fresh
/// daemon data home. The orchestrator handles: daemon startup, session
/// creation, agent join (leader + worker + reviewer), task creation, worker
/// advance to in-progress, and submit-for-review. This test then launches the
/// Monitor UI and asserts the review inspector surfaces the identifiers the
/// Slice 5 badge/card/banner set emits.
@MainActor
final class SwarmFullFlowTests: HarnessMonitorUITestCase {
  static let swarmStartupTimeout: TimeInterval = 25
  static let swarmActionTimeout: TimeInterval = 10

  func testSwarmFullFlowRendersReviewUI() throws {
    let harness = try HarnessMonitorSwarmE2ELiveHarness.setUp(for: self)
    let app = launchSwarmMonitor(using: harness)

    openSeededSessionCockpit(in: app, harness: harness)
    selectSeededTask(in: app, harness: harness)
    assertReviewInspectorSurfacesPresented(in: app, harness: harness)
  }

  private func launchSwarmMonitor(
    using harness: HarnessMonitorSwarmE2ELiveHarness
  ) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    terminateIfRunning(app)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment = harness.appLaunchEnvironment
    app.launch()
    XCTAssertTrue(
      waitUntil(timeout: Self.swarmStartupTimeout) {
        if app.state != .runningForeground {
          app.activate()
        }
        return app.state == .runningForeground || self.mainWindow(in: app).exists
      },
      harness.diagnosticsSummary()
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.swarmStartupTimeout) {
        let window = self.mainWindow(in: app)
        return window.exists && window.frame.width > 0 && window.frame.height > 0
      },
      harness.diagnosticsSummary()
    )
    return app
  }

  private func openSeededSessionCockpit(
    in app: XCUIApplication,
    harness: HarnessMonitorSwarmE2ELiveHarness
  ) {
    let sessionIdentifier = Accessibility.sessionRow(harness.sessionID)
    let sessionRow = sessionTrigger(in: app, identifier: sessionIdentifier)
    XCTAssertTrue(
      waitForElement(sessionRow, timeout: Self.swarmStartupTimeout),
      """
      Expected seeded swarm session row \(sessionIdentifier)
      \(harness.diagnosticsSummary())
      """
    )
    let toolbarState = element(in: app, identifier: Accessibility.toolbarChromeState)
    let reached = {
      self.sessionRowIsSelected(sessionRow)
        || toolbarState.label.contains("windowTitle=Cockpit")
    }
    let attempt = {
      self.tapSession(in: app, identifier: sessionIdentifier)
      return self.waitUntil(timeout: 1.5) { reached() }
    }
    if !reached() {
      let ok = attempt() || attempt() || attempt()
      XCTAssertTrue(
        ok,
        """
        Seeded session row never reported selection.
        toolbarState=\(toolbarState.label)
        \(harness.diagnosticsSummary())
        """
      )
    }
  }

  private func selectSeededTask(
    in app: XCUIApplication,
    harness: HarnessMonitorSwarmE2ELiveHarness
  ) {
    let taskIdentifier = "harness.session.task.\(harness.taskID)"
    let taskCard = element(in: app, identifier: taskIdentifier)
    XCTAssertTrue(
      waitForElement(taskCard, timeout: Self.swarmActionTimeout),
      """
      Seeded task card did not render.
      identifier=\(taskIdentifier)
      \(harness.diagnosticsSummary())
      """
    )
    taskCard.firstMatch.tap()
  }

  private func assertReviewInspectorSurfacesPresented(
    in app: XCUIApplication,
    harness: HarnessMonitorSwarmE2ELiveHarness
  ) {
    let awaitingBadge = element(
      in: app, identifier: Accessibility.awaitingReviewBadge(harness.taskID))
    let roundCounter = element(
      in: app, identifier: Accessibility.roundCounter(harness.taskID))
    let inspectorCard = element(in: app, identifier: Accessibility.taskInspectorCard)

    XCTAssertTrue(
      waitUntil(timeout: Self.swarmActionTimeout) {
        inspectorCard.exists && (awaitingBadge.exists || roundCounter.exists)
      },
      """
      Review inspector surfaces never rendered for seeded task.
      awaitingBadge=\(awaitingBadge.exists) roundCounter=\(roundCounter.exists)
      \(harness.diagnosticsSummary())
      """
    )
  }
}
