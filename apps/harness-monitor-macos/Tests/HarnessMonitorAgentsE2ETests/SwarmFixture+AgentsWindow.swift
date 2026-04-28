import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension SwarmFixture {
  func openAgentsWindow() {
    dismissTaskActionsSheetIfPresent()
    let identifier = Accessibility.agentsButton
    trace("open-agents.begin", app: app, details: ["identifier": identifier])
    testCase.tapElement(in: app, identifier: identifier)
    let opened = testCase.waitUntil(timeout: 10) {
      self.testCase.element(in: self.app, identifier: Accessibility.agentTuiLaunchPane).exists
        || self.testCase.element(in: self.app, identifier: Accessibility.agentTuiSessionPane)
          .exists
    }
    if opened {
      trace("open-agents.success", app: app)
    } else {
      trace("open-agents.timeout", app: app)
    }
    XCTAssertTrue(
      opened,
      "Expected Agents window to appear\n\(diagnosticsSummary())"
    )
  }

  func closeAgentsWindow() {
    let agentsWindow = testCase.element(in: app, identifier: Accessibility.agentsWindow)
    let agentsState = testCase.element(in: app, identifier: Accessibility.agentTuiState)
    let launchPane = testCase.element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let sessionPane = testCase.element(in: app, identifier: Accessibility.agentTuiSessionPane)
    guard
      agentsWindow.exists || agentsState.exists || launchPane.exists || sessionPane.exists
    else {
      return
    }
    trace("close-agents.begin", app: app)
    app.typeKey("w", modifierFlags: .command)
    let closed = testCase.waitUntil(timeout: 10) {
      !agentsWindow.exists && !agentsState.exists && !launchPane.exists && !sessionPane.exists
    }
    if closed {
      trace("close-agents.success", app: app)
    } else {
      trace("close-agents.timeout", app: app)
    }
    XCTAssertTrue(
      closed,
      "Expected Agents window to close\n\(diagnosticsSummary())"
    )
  }

  func selectAgentsTask(_ taskID: String) {
    let tabID = Accessibility.agentsTaskTab(taskID)
    let selectionID = Accessibility.agentsTaskSelection(taskID)
    let taskTab = testCase.element(in: app, identifier: tabID)
    let sidebar = agentsSidebarScrollView()
    trace(
      "select-agents-task.begin",
      app: app,
      details: [
        "task_id": taskID,
        "tab_identifier": tabID,
        "selection_identifier": selectionID,
      ]
    )
    assertAgentsSidebarReady(sidebar)
    waitUntilAgentsTaskVisible(taskTab, sidebar: sidebar, taskID: taskID)
    testCase.tapElement(in: app, identifier: tabID)
    assertAgentsTaskSelected(taskID)
    expectIdentifier(selectionID)
  }

  private func assertAgentsSidebarReady(_ sidebar: XCUIElement) {
    let sidebarReady = testCase.waitUntil(timeout: 5) {
      if self.app.state != .runningForeground {
        self.app.activate()
      }
      return sidebar.exists && !sidebar.frame.isEmpty && sidebar.scrollBars.firstMatch.exists
    }
    XCTAssertTrue(
      sidebarReady,
      "Expected Agents sidebar scroll view to be available\n\(diagnosticsSummary())"
    )
  }

  private func waitUntilAgentsTaskVisible(
    _ taskTab: XCUIElement,
    sidebar: XCUIElement,
    taskID: String
  ) {
    let taskVisible = testCase.waitUntil(timeout: 12) {
      if self.app.state != .runningForeground {
        self.app.activate()
      }
      if self.elementIsVisible(taskTab, in: sidebar) {
        return true
      }
      sidebar.scroll(byDeltaX: 0, deltaY: -max(240, sidebar.frame.height * 0.9))
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
      return false
    }
    if taskVisible {
      trace("select-agents-task.visible", app: app, details: ["task_id": taskID])
    } else {
      trace("select-agents-task.timeout", app: app, details: ["task_id": taskID])
    }
    XCTAssertTrue(
      taskVisible,
      """
      Expected Agents task tab \(taskID) to become visible inside the Agents sidebar.
      agentsWindowState=\(currentAgentsWindowStateLabel())
      \(diagnosticsSummary())
      """
    )
  }

  private func assertAgentsTaskSelected(_ taskID: String) {
    let selected = testCase.waitUntil(timeout: 5) {
      self.currentAgentsWindowStateLabel().contains("selection=task:\(taskID)")
    }
    XCTAssertTrue(
      selected,
      """
      Expected Agents task tab \(taskID) to become selected after tap.
      agentsWindowState=\(currentAgentsWindowStateLabel())
      \(diagnosticsSummary())
      """
    )
  }

  private func currentAgentsWindowStateLabel() -> String {
    let identifiers = [Accessibility.agentTuiState, Accessibility.agentsWindow]
    for identifier in identifiers {
      let matches = app.descendants(matching: .any).matching(identifier: identifier)
      let searchCount = min(matches.count, 8)
      for index in 0..<searchCount {
        let candidate = matches.element(boundBy: index)
        guard candidate.exists, candidate.label.isEmpty == false else {
          continue
        }
        return candidate.label
      }
    }
    return ""
  }

  private func agentsSidebarScrollView() -> XCUIElement {
    let createRow = testCase.element(in: app, identifier: Accessibility.agentTuiCreateTab)
    let launchPane = testCase.element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let anchor = createRow.exists ? createRow : launchPane
    let agentsWindow = testCase.window(in: app, containing: anchor)
    return agentsWindow.scrollViews.element(boundBy: 0)
  }

  private func elementIsVisible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
    guard
      element.exists,
      !element.frame.isEmpty,
      container.exists,
      !container.frame.isEmpty
    else {
      return false
    }

    let visibleFrame = element.frame.intersection(container.frame)
    return !visibleFrame.isNull && !visibleFrame.isEmpty
  }
}
