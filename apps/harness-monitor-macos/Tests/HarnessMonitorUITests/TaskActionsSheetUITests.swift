import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class TaskActionsSheetUITests: HarnessMonitorUITestCase {
  func testManageTaskOpens() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    openAgentsWindow(in: app)
    selectFirstAgentsTask(in: app)

    let manageButton = button(in: app, identifier: Accessibility.manageTaskOpenButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        manageButton.exists && !manageButton.frame.isEmpty
      },
      "Agents task pane should expose a Manage Task button"
    )
    tapElement(in: app, identifier: Accessibility.manageTaskOpenButton)

    let sheet = element(in: app, identifier: Accessibility.taskActionsSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Task actions sheet should appear after tapping Manage Task"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Sheet should dismiss on Escape"
    )
  }
}

extension TaskActionsSheetUITests {
  fileprivate func openAgentsWindow(in app: XCUIApplication) {
    app.activate()
    let trigger = button(in: app, identifier: Accessibility.agentsButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        trigger.exists && !trigger.frame.isEmpty
      },
      "Cockpit Agents action button should be visible"
    )
    tapElement(in: app, identifier: Accessibility.agentsButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          || self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
          || self.button(in: app, identifier: Accessibility.agentsTaskTab("task-ui")).exists
      },
      "Agents window should open after tapping the cockpit Agents action"
    )
  }

  fileprivate func selectFirstAgentsTask(in app: XCUIApplication) {
    let taskTab = button(in: app, identifier: Accessibility.agentsTaskTab("task-ui"))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        taskTab.exists && !taskTab.frame.isEmpty
      },
      "Agents sidebar should expose the preview task row"
    )
    tapElement(in: app, identifier: Accessibility.agentsTaskTab("task-ui"))
    let detailCard = element(in: app, identifier: Accessibility.agentsTaskCard)
    XCTAssertTrue(
      detailCard.waitForExistence(timeout: Self.actionTimeout),
      "Agents task detail pane should render after selecting a task"
    )
  }
}
