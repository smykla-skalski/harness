import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorTimelineUITests: HarnessMonitorUITestCase {
  func testTimelineCursorNavigationChangesVisibleEntriesAndResetsAfterSessionSwitch() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySession = previewSessionTrigger(in: app)
    let secondarySession = sessionTrigger(
      in: app,
      identifier: Accessibility.signalRegressionSecondarySessionRow
    )

    XCTAssertTrue(primarySession.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(secondarySession.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)

    let olderButton = button(in: app, identifier: Accessibility.sessionTimelineOlderButton)
    let latestButton = button(in: app, identifier: Accessibility.sessionTimelineLatestButton)
    let newerButton = button(in: app, identifier: Accessibility.sessionTimelineNewerButton)
    let navigationStatus = element(
      in: app,
      identifier: Accessibility.sessionTimelineNavigationStatus
    )

    assertInitialTimelineCursorState(
      in: app,
      navigationStatus: navigationStatus,
      olderButton: olderButton,
      latestButton: latestButton,
      newerButton: newerButton
    )
    assertTimelineCursorTransitions(
      in: app,
      navigationStatus: navigationStatus,
      olderButton: olderButton,
      latestButton: latestButton,
      newerButton: newerButton
    )
    assertTimelineCursorResetsAfterSessionSwitch(in: app)
  }

  func testTimelineRendersDecisionCardsAndDisplayOnlyEvents() throws {
    let decisionID = "acp-permission:preview-acp-permission-1"
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )

    tapPreviewSession(in: app)

    let decisionCard = timelineNode(in: app, key: "decision-\(decisionID)")
    XCTAssertTrue(decisionCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(decisionCard.label.contains("Decision"))
    XCTAssertTrue(decisionCard.label.contains("Severity Needs user"))
    XCTAssertTrue(decisionCard.label.contains("actions"))
    XCTAssertTrue(
      button(
        in: app,
        identifier: Accessibility.sessionTimelineActionButton(
          decisionID: decisionID,
          actionID: "approve-selected"
        )
      )
      .waitForExistence(timeout: Self.actionTimeout)
    )

    let eventCard = timelineNode(in: app, key: "entry-codex-worker-codex-tool-result-4")
    XCTAssertTrue(eventCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(eventCard.label.contains("Event"))
    XCTAssertTrue(eventCard.label.contains("No actions"))
  }

  func testExistingSignalsRemainVisibleAfterSwitchingSessions() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "signal-regression"]
    )

    let primarySession = previewSessionTrigger(in: app)
    let secondarySession = sessionTrigger(
      in: app,
      identifier: Accessibility.signalRegressionSecondarySessionRow
    )
    let primarySignal = button(in: app, identifier: Accessibility.previewSignalCard)
    let noSignalsState = app.staticTexts["No signals"]
    let signalSheet = element(in: app, identifier: Accessibility.signalDetailSheet)

    XCTAssertTrue(primarySession.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(secondarySession.waitForExistence(timeout: Self.actionTimeout))

    if !primarySignal.waitForExistence(timeout: 1.5) {
      tapPreviewSession(in: app)
    }

    XCTAssertTrue(
      primarySignal.waitForExistence(timeout: Self.actionTimeout),
      "Existing session signals should be visible when the cockpit opens"
    )
    tapButton(in: app, identifier: Accessibility.previewSignalCard)
    XCTAssertTrue(
      signalSheet.waitForExistence(timeout: Self.actionTimeout),
      "Selecting a signal row should open the signal detail sheet"
    )

    tapSession(in: app, identifier: Accessibility.signalRegressionSecondarySessionRow)
    XCTAssertTrue(
      noSignalsState.waitForExistence(timeout: Self.actionTimeout),
      "A different session without signals should replace the previous signal list"
    )

    tapPreviewSession(in: app)
    XCTAssertTrue(
      primarySignal.waitForExistence(timeout: Self.actionTimeout),
      "Existing signals should still be visible after switching away and back"
    )
  }

  private func assertInitialTimelineCursorState(
    in app: XCUIApplication,
    navigationStatus: XCUIElement,
    olderButton: XCUIElement,
    latestButton: XCUIElement,
    newerButton: XCUIElement
  ) {
    XCTAssertTrue(navigationStatus.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(olderButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(latestButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(newerButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        navigationStatus.label == "Latest 6 of 32"
      }
    )
    XCTAssertTrue(timelineNode(in: app, key: "entry-paged-timeline-32").exists)
    XCTAssertTrue(timelineNode(in: app, key: "entry-paged-timeline-27").exists)
    XCTAssertFalse(timelineNode(in: app, key: "entry-paged-timeline-26").exists)
    XCTAssertTrue(olderButton.isEnabled)
    XCTAssertTrue(latestButton.isEnabled)
    XCTAssertFalse(newerButton.isEnabled)
  }

  private func assertTimelineCursorTransitions(
    in app: XCUIApplication,
    navigationStatus: XCUIElement,
    olderButton: XCUIElement,
    latestButton: XCUIElement,
    newerButton: XCUIElement
  ) {
    tapButton(in: app, identifier: Accessibility.sessionTimelineOlderButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        navigationStatus.label == "Showing 7-12 of 32"
      }
    )
    XCTAssertTrue(timelineNode(in: app, key: "entry-paged-timeline-26").exists)
    XCTAssertTrue(timelineNode(in: app, key: "entry-paged-timeline-21").exists)
    XCTAssertFalse(timelineNode(in: app, key: "entry-paged-timeline-32").exists)
    XCTAssertTrue(olderButton.isEnabled)
    XCTAssertTrue(newerButton.isEnabled)

    tapButton(in: app, identifier: Accessibility.sessionTimelineNewerButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        navigationStatus.label == "Latest 6 of 32"
      }
    )
    XCTAssertTrue(timelineNode(in: app, key: "entry-paged-timeline-32").exists)
    XCTAssertFalse(newerButton.isEnabled)

    tapButton(in: app, identifier: Accessibility.sessionTimelineOlderButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        navigationStatus.label == "Showing 7-12 of 32"
      }
    )

    tapButton(in: app, identifier: Accessibility.sessionTimelineLatestButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        navigationStatus.label == "Latest 6 of 32"
      }
    )
    XCTAssertTrue(timelineNode(in: app, key: "entry-paged-timeline-32").exists)
    XCTAssertFalse(timelineNode(in: app, key: "entry-paged-timeline-26").exists)
  }

  private func assertTimelineCursorResetsAfterSessionSwitch(in app: XCUIApplication) {
    tapSession(in: app, identifier: Accessibility.signalRegressionSecondarySessionRow)

    XCTAssertTrue(
      timelineNode(in: app, key: "entry-codex-worker-codex-tool-result-4")
        .waitForExistence(timeout: Self.actionTimeout)
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.sessionTimelineNavigationStatus).label
          == "Latest 4 of 4"
      }
    )

    tapPreviewSession(in: app)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.sessionTimelineNavigationStatus).label
          == "Latest 6 of 32"
      }
    )
    XCTAssertTrue(
      timelineNode(in: app, key: "entry-paged-timeline-32")
        .waitForExistence(timeout: Self.actionTimeout)
    )
    XCTAssertFalse(timelineNode(in: app, key: "entry-paged-timeline-26").exists)
  }

  private func timelineNode(in app: XCUIApplication, key: String) -> XCUIElement {
    element(in: app, identifier: Accessibility.sessionTimelineNode(key))
  }
}
