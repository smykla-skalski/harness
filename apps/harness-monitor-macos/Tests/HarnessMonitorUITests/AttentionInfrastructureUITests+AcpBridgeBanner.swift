import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class AttentionInfrastructureUITestsAcpBridgeBanner:
  HarnessMonitorUITestCase,
  WorkspaceWindowUITestSupporting
{
  func testBridgeBannerRendersActionsAndFrontHallRuntimeRemainsVisible() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1",
        "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_RUNNING": "0",
      ]
    )

    let banner = element(in: app, identifier: Accessibility.contentAcpBridgeBanner)
    XCTAssertTrue(
      waitForElement(banner, timeout: Self.uiTimeout),
      "ACP bridge outage banner should render when the preview host bridge is down"
    )
    let openLog = button(in: app, identifier: Accessibility.contentAcpBridgeOpenLogButton)
    XCTAssertTrue(waitForElement(openLog, timeout: Self.actionTimeout))
    tapButton(in: app, identifier: Accessibility.contentAcpBridgeOpenLogButton)

    let runDoctor = button(in: app, identifier: Accessibility.contentAcpBridgeRunDoctorButton)
    XCTAssertTrue(waitForElement(runDoctor, timeout: Self.actionTimeout))
    tapButton(in: app, identifier: Accessibility.contentAcpBridgeRunDoctorButton)

    openWorkspaceWindow(in: app)
    let agentRow = element(in: app, identifier: Accessibility.agentTuiExternalTab("worker-codex"))
    XCTAssertTrue(waitForElement(agentRow, timeout: Self.uiTimeout))
    tapViaCoordinate(in: app, element: agentRow)

    let runtimeStrip = element(
      in: app,
      identifier: Accessibility.agentRuntimeStrip("worker-codex")
    )
    XCTAssertTrue(
      waitForElement(runtimeStrip, timeout: Self.uiTimeout),
      "Front-hall runtime strip should remain available even during bridge outage"
    )
  }
}
