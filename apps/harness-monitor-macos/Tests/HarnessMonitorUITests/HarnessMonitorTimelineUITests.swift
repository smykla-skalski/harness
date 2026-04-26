import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorTimelineUITests: HarnessMonitorUITestCase {
  func testTimelinePaginationChangesVisibleEntriesAndResetsAfterSessionSwitch() throws {
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

    let previousButton = button(
      in: app,
      identifier: Accessibility.sessionTimelinePaginationPrevious
    )
    let nextButton = button(
      in: app,
      identifier: Accessibility.sessionTimelinePaginationNext
    )
    let pageStatus = element(
      in: app,
      identifier: Accessibility.sessionTimelinePaginationStatus
    )
    let pageSizePicker = popUpButton(
      in: app,
      identifier: Accessibility.sessionTimelinePageSizePicker
    )

    assertInitialTimelinePaginationState(
      in: app,
      pageStatus: pageStatus,
      previousButton: previousButton,
      nextButton: nextButton,
      pageSizePicker: pageSizePicker
    )
    assertTimelinePageSizeTransitions(
      in: app,
      pageStatus: pageStatus,
      previousButton: previousButton,
      nextButton: nextButton
    )
    assertTimelinePaginationResetsAfterSessionSwitch(in: app)
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

  private func assertInitialTimelinePaginationState(
    in app: XCUIApplication,
    pageStatus: XCUIElement,
    previousButton: XCUIElement,
    nextButton: XCUIElement,
    pageSizePicker: XCUIElement
  ) {
    XCTAssertTrue(pageStatus.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(previousButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(nextButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(pageSizePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 32"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(app.staticTexts["Paged timeline event 22"].exists)
    XCTAssertFalse(previousButton.isEnabled)
    XCTAssertTrue(nextButton.isEnabled)
    XCTAssertEqual(pageStatus.label, "Page 1 of 4")
  }

  private func assertTimelinePageSizeTransitions(
    in app: XCUIApplication,
    pageStatus: XCUIElement,
    previousButton: XCUIElement,
    nextButton: XCUIElement
  ) {
    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.sessionTimelinePageSizePicker,
      optionTitle: "30"
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 1 of 2"
      }
    )
    XCTAssertTrue(app.staticTexts["Paged timeline event 32"].exists)
    XCTAssertFalse(app.staticTexts["Paged timeline event 02"].exists)

    tapButton(in: app, identifier: Accessibility.sessionTimelinePaginationPageButton(2))

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 2 of 2"
      }
    )
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 02"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(nextButton.isEnabled)

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.sessionTimelinePageSizePicker,
      optionTitle: "15"
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 3 of 3"
      }
    )
    XCTAssertTrue(app.staticTexts["Paged timeline event 02"].exists)
    XCTAssertTrue(previousButton.isEnabled)
    XCTAssertFalse(nextButton.isEnabled)

    tapButton(in: app, identifier: Accessibility.sessionTimelinePaginationPageButton(2))

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 2 of 3"
      }
    )
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 17"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(app.staticTexts["Paged timeline event 32"].exists)
    XCTAssertTrue(previousButton.isEnabled)
    XCTAssertTrue(nextButton.isEnabled)

    tapButton(in: app, identifier: Accessibility.sessionTimelinePaginationPageButton(3))

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 3 of 3"
      }
    )
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 02"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(nextButton.isEnabled)
  }

  private func assertTimelinePaginationResetsAfterSessionSwitch(in app: XCUIApplication) {
    tapSession(in: app, identifier: Accessibility.signalRegressionSecondarySessionRow)

    XCTAssertTrue(
      app.staticTexts["worker-codex received a result from Edit"].waitForExistence(
        timeout: Self.actionTimeout
      )
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !self.element(in: app, identifier: Accessibility.sessionTimelinePagination).exists
      }
    )

    tapPreviewSession(in: app)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.sessionTimelinePaginationStatus).label
          == "Page 1 of 4"
      }
    )
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 32"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(app.staticTexts["Paged timeline event 22"].exists)
  }
}
