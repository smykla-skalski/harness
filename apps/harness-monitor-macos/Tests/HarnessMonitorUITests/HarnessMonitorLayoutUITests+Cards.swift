import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension HarnessMonitorLayoutUITests {
  func testSessionCockpitTaskAndAgentCardsShareHeight() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let taskUI = element(in: app, identifier: Accessibility.taskUICard)
    let taskRouting = element(in: app, identifier: Accessibility.taskRoutingCard)
    let leaderCard = element(in: app, identifier: Accessibility.leaderAgentCard)
    let workerCard = element(in: app, identifier: Accessibility.workerAgentCard)

    XCTAssertTrue(taskUI.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(taskRouting.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(leaderCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(workerCard.waitForExistence(timeout: Self.actionTimeout))

    assertEqualHeights([taskUI, taskRouting], tolerance: 10)
    assertEqualHeights([leaderCard, workerCard], tolerance: 10)
  }

  func testTaskDropPreviewTaskCardHidesContextAndKeepsStatusRowVisible() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "task-drop"]
    )

    let taskCard = element(in: app, identifier: Accessibility.taskDropQueueCard)
    let workerCard = element(in: app, identifier: Accessibility.workerAgentCard)
    let context = app.staticTexts["Drag this open task onto the busy worker card."]

    XCTAssertTrue(taskCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(workerCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(
      context.exists,
      "Cockpit task cards should keep the compact two-row layout and hide task context"
    )
    XCTAssertLessThan(
      taskCard.frame.height,
      workerCard.frame.height,
      "Compact task cards should stay shorter than the full worker cards in the same cockpit grid"
    )
  }

}
