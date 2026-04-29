import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension AgentsWindowUITests {
  func testAcpRuntimeStripAndDisclosureAppearForManagedAgent() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openAgentsWindow(in: app)

    let agentRow = element(in: app, identifier: Accessibility.agentTuiExternalTab("worker-codex"))
    XCTAssertTrue(waitForElement(agentRow, timeout: Self.uiTimeout))
    tapViaCoordinate(in: app, element: agentRow)

    let runtimeStrip = element(
      in: app,
      identifier: Accessibility.agentRuntimeStrip("worker-codex")
    )
    let disclosure = element(
      in: app,
      identifier: Accessibility.agentRuntimeDisclosure("worker-codex")
    )
    let watchdog = element(
      in: app,
      identifier: Accessibility.agentRuntimeWatchdog("worker-codex")
    )
    let pendingPermissions = element(
      in: app,
      identifier: Accessibility.agentRuntimePendingPermissions("worker-codex")
    )
    let deadline = element(
      in: app,
      identifier: Accessibility.agentRuntimeDeadline("worker-codex")
    )
    XCTAssertTrue(
      waitForElement(runtimeStrip, timeout: Self.uiTimeout),
      "Managed ACP agent detail should render the runtime strip"
    )
    XCTAssertTrue(
      waitForElement(disclosure, timeout: Self.uiTimeout),
      "Managed ACP agent detail should render the runtime disclosure"
    )
    XCTAssertTrue(
      waitForElement(watchdog, timeout: Self.uiTimeout),
      "Managed ACP agent detail should render the watchdog badge"
    )
    XCTAssertTrue(
      waitForElement(pendingPermissions, timeout: Self.uiTimeout),
      "Managed ACP agent detail should render the pending-permissions chip"
    )
    XCTAssertTrue(
      waitForElement(deadline, timeout: Self.uiTimeout),
      "Managed ACP agent detail should render the prompt-deadline chip"
    )
    XCTAssertLessThan(
      runtimeStrip.frame.minY,
      disclosure.frame.minY,
      "The always-visible runtime strip should appear above the disclosure"
    )
  }

  func testNonAcpAgentDetailOmitsRuntimeStrip() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openAgentsWindow(in: app)

    let leaderRow = element(in: app, identifier: Accessibility.agentTuiExternalTab("leader-claude"))
    XCTAssertTrue(waitForElement(leaderRow, timeout: Self.uiTimeout))
    tapViaCoordinate(in: app, element: leaderRow)

    let runtimeStrip = element(
      in: app,
      identifier: Accessibility.agentRuntimeStrip("leader-claude")
    )
    XCTAssertFalse(
      waitForElement(runtimeStrip, timeout: Self.fastPollInterval),
      "Non-ACP agent detail should not surface ACP runtime chrome"
    )
  }
}
