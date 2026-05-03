import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension WorkspaceWindowUITests {
  func testCommandFMovesKeyboardFocusToWorkspaceDecisionSearchField() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openWorkspaceWindow(in: app)

    let filterState = element(in: app, identifier: Accessibility.workspaceDecisionFilterState)
    XCTAssertTrue(
      waitForElement(filterState, timeout: Self.actionTimeout),
      "Decision filter state marker must be visible before sending Cmd-F"
    )

    app.activate()
    app.typeKey("f", modifierFlags: .command)
    app.typeText("zzznomatch")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        filterState.label.contains("query=zzznomatch")
      },
      """
      Cmd-F should route keyboard focus to the workspace decision search field and \
      apply the typed text as a filter query.
      filterState=\(filterState.label)
      """
    )
  }

  func testCollapsedWorkspaceSidebarCommandFRevealsAndFocusesSearch() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openWorkspaceWindow(in: app)

    let filterState = element(in: app, identifier: Accessibility.workspaceDecisionFilterState)
    XCTAssertTrue(
      waitForElement(filterState, timeout: Self.actionTimeout),
      "Decision filter state marker must be visible before collapsing the sidebar"
    )

    // Collapse sidebar via Cmd-Ctrl-S.
    app.activate()
    app.typeKey("s", modifierFlags: [.command, .control])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !filterState.exists
      },
      "Decision filter state should disappear when the workspace sidebar is collapsed"
    )

    // Cmd-F should re-expand the sidebar and route focus to the search field.
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(
      waitForElement(filterState, timeout: Self.actionTimeout),
      "Decision filter state should reappear after Cmd-F re-expands the collapsed sidebar"
    )

    app.typeText("zzznomatch")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        filterState.label.contains("query=zzznomatch")
      },
      """
      After sidebar reveal via Cmd-F, typing should filter decisions via the search field.
      filterState=\(filterState.label)
      """
    )
  }
}
