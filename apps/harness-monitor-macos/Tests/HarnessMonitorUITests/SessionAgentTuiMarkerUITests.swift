import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SessionAgentTuiMarkerUITests: HarnessMonitorUITestCase {
  func testTuiMarkerVisibleOnAgentCardsInMixedSession() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "agent-tui-overflow"]
    )

    tapPreviewSession(in: app)

    let leaderCard = element(in: app, identifier: Accessibility.leaderAgentCard)
    XCTAssertTrue(
      waitForElement(leaderCard, timeout: Self.actionTimeout),
      "Leader agent card should appear in the cockpit"
    )

    let leaderTuiMarker = element(
      in: app,
      identifier: Accessibility.leaderAgentTuiMarker
    )
    XCTAssertTrue(
      waitForElement(leaderTuiMarker, timeout: Self.fastActionTimeout),
      "Leader card should show a TUI marker when a TUI session exists for that agent"
    )

    let workerTuiMarker = element(
      in: app,
      identifier: Accessibility.workerAgentTuiMarker
    )
    XCTAssertTrue(
      waitForElement(workerTuiMarker, timeout: Self.fastActionTimeout),
      "Worker card should show a TUI marker when a TUI session exists for that agent"
    )
  }

  func testTuiMarkerAbsentWhenNoTuiSessionExists() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    tapPreviewSession(in: app)

    let leaderCard = element(in: app, identifier: Accessibility.leaderAgentCard)
    XCTAssertTrue(
      waitForElement(leaderCard, timeout: Self.actionTimeout),
      "Leader agent card should appear in the cockpit"
    )

    let leaderTuiMarker = element(
      in: app,
      identifier: Accessibility.leaderAgentTuiMarker
    )
    XCTAssertFalse(
      leaderTuiMarker.exists,
      "Leader card should not show a TUI marker when no TUI session exists"
    )

    let workerTuiMarker = element(
      in: app,
      identifier: Accessibility.workerAgentTuiMarker
    )
    XCTAssertFalse(
      workerTuiMarker.exists,
      "Worker card should not show a TUI marker when no TUI session exists"
    )
  }
}
