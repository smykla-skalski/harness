import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorTaskBoardNavigationUITests: HarnessMonitorUITestCase {
  func testLinkedReviewTicketReopensReportWithSpawnedTaskAction() throws {
    let itemID = "preview-linked-review"
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "task-board-board-only"
      ]
    )

    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let boardItem = button(in: app, identifier: "harness.task-board.api-item.\(itemID)")
    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(boardItem.waitForExistence(timeout: Self.actionTimeout))

    boardItem.click()
    XCTAssertEqual(boardItem.value as? String, "Selected")
    app.typeKey(.return, modifierFlags: [])

    let managementPanel = element(
      in: app,
      identifier: "harness.task-board.manage-item.\(itemID)"
    )
    let reviewReport = element(
      in: app,
      identifier: "harness.task-board.manage-item.review-report"
    )
    let openSpawnedTask = button(
      in: app,
      identifier: "harness.task-board.manage-item.open-spawned-task"
    )
    XCTAssertTrue(managementPanel.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reviewReport.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(openSpawnedTask.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Completed"].exists)

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !managementPanel.exists },
      "Manage Board Item should dismiss without losing the originating ticket."
    )

    boardItem.doubleClick()
    XCTAssertTrue(managementPanel.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reviewReport.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Completed"].exists)
  }
}
