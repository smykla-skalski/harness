import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class CreateTaskSheetUITests: HarnessMonitorUITestCase {
  func testActionDockOpensSheet() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let taskFlow = button(in: app, title: "Task Flow")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        taskFlow.exists && !taskFlow.frame.isEmpty
      },
      "Action dock should expose a Task Flow button"
    )
    tapButton(in: app, title: "Task Flow")

    let sheet = element(in: app, identifier: Accessibility.createTaskSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Create task sheet should appear after tapping Task Flow"
    )

    let titleField = editableField(in: app, identifier: Accessibility.createTaskTitleField)
    XCTAssertTrue(
      titleField.waitForExistence(timeout: Self.actionTimeout),
      "Create task sheet should expose the title field"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Sheet should dismiss on Escape"
    )
  }
}
