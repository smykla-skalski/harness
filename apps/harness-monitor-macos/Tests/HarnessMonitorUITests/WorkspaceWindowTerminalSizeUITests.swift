import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class WorkspaceWindowTerminalSizeUITests:
  HarnessMonitorUITestCase,
  WorkspaceWindowUITestSupporting
{
  func testTerminalSizeRemainsStableAfterStartAndSelection() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Claude", prompt: "viewport size test")
    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(waitForElement(state, timeout: Self.actionTimeout))
    guard let initialSize = agentTuiSize(from: state.label) else {
      XCTFail("State marker should expose terminal size after start")
      return
    }
    XCTAssertNotEqual(
      initialSize.rows,
      30,
      "Terminal should use viewport-derived size, not daemon default 30 rows"
    )
    tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        state.label.contains("selection=create")
      }
    )
    let sessionRow = element(
      in: app,
      identifier: Accessibility.agentTuiTab("preview-agent-tui-1")
    )
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))
    sessionRow.click()
    let sizeStable = waitUntil(timeout: Self.actionTimeout) {
      guard let currentSize = self.agentTuiSize(from: state.label) else {
        return false
      }
      return state.label.contains("selection=session:preview-agent-tui-1")
        && currentSize.rows == initialSize.rows
        && currentSize.cols == initialSize.cols
    }
    let finalState = state.label
    XCTAssertTrue(
      sizeStable,
      """
      Terminal size should remain stable after switching away and back.
      Initial: \(initialSize.rows)x\(initialSize.cols)
      Final state: \(finalState)
      """
    )
  }

  func testTerminalSizeRemainsStableAfterClosingAndReopeningWorkspaceWindow() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Claude", prompt: "reopen viewport size test")
    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(waitForElement(state, timeout: Self.actionTimeout))
    guard let initialSize = agentTuiSize(from: state.label) else {
      XCTFail("State marker should expose terminal size after start")
      return
    }

    closeWorkspaceWindow(in: app)
    reopenWorkspaceWindow(in: app)

    let sizeStable = waitUntil(timeout: Self.actionTimeout) {
      guard let currentSize = self.agentTuiSize(from: state.label) else {
        return false
      }
      return state.label.contains("selection=session:preview-agent-tui-1")
        && currentSize.rows == initialSize.rows
        && currentSize.cols == initialSize.cols
    }
    let finalState = state.label
    XCTAssertTrue(
      sizeStable,
      """
      Terminal size should remain stable after closing and reopening the Workspace window.
      Initial: \(initialSize.rows)x\(initialSize.cols)
      Final state: \(finalState)
      """
    )
  }
}
