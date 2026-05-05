import CoreGraphics
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension WorkspaceWindowUITests {
  func testCreatePaneSidebarChromeMatchesNativeInsetLayout() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
    let createRow = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(waitForElement(createRow, timeout: Self.actionTimeout))
    let agentWindow = window(in: app, containing: createRow)
    XCTAssertTrue(agentWindow.exists)
    let toolbar = agentWindow.toolbars.firstMatch
    XCTAssertTrue(waitForElement(toolbar, timeout: Self.actionTimeout))
    XCTAssertGreaterThan(
      toolbar.buttons.count,
      0,
      "Workspace window should expose toolbar controls in native window chrome"
    )
    let buttonLeadingInset =
      toolbar.buttons.allElementsBoundByIndex
      .filter { $0.exists && !$0.frame.isEmpty }
      .map { $0.frame.minX - agentWindow.frame.minX }
      .min()
      ?? CGFloat.greatestFiniteMagnitude
    let searchLeadingInset =
      agentWindow.searchFields.allElementsBoundByIndex
      .filter { $0.exists && !$0.frame.isEmpty }
      .map { $0.frame.minX - agentWindow.frame.minX }
      .min()
      ?? CGFloat.greatestFiniteMagnitude
    let leadingChromeInset = min(buttonLeadingInset, searchLeadingInset)
    let rowTopInset = createRow.frame.minY - agentWindow.frame.minY
    XCTAssertLessThan(
      leadingChromeInset,
      CGFloat.greatestFiniteMagnitude,
      "Workspace window should expose a visible leading toolbar control"
    )
    XCTAssertLessThan(
      leadingChromeInset,
      176,
      "Workspace window chrome should stay near the leading window edge"
    )
    XCTAssertGreaterThan(
      rowTopInset,
      44,
      "Agents sidebar content should start below the native toolbar controls"
    )
    XCTAssertLessThan(
      rowTopInset,
      120,
      "Agents sidebar content should stay visually close to the toolbar"
    )
  }

  func testAgentDetailColumnsStayScrollableInsideWorkspaceChrome() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openWorkspaceWindow(in: app)
    let agentID = "worker-codex"

    let agentRow = element(
      in: app,
      identifier: Accessibility.agentTuiExternalTab(agentID)
    )
    XCTAssertTrue(waitForElement(agentRow, timeout: Self.uiTimeout))

    let workspaceWindow = window(in: app, containing: agentRow)
    let rowTopInset = agentRow.frame.minY - workspaceWindow.frame.minY
    let sidebarDiagnostics = """
      workspaceWindow: \(workspaceWindow.frame)
      agentRow: \(agentRow.frame)
      rowTopInset: \(rowTopInset)
      """
    XCTAssertGreaterThan(
      rowTopInset,
      64,
      "Agent sidebar rows should not slide under the native window controls.\n\(sidebarDiagnostics)"
    )

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(
      waitForElement(state, timeout: Self.actionTimeout),
      "Workspace state marker should publish before the worker row is tapped"
    )
    ensureAgentDetailSelection(
      in: app,
      agentID: agentID,
      agentRow: agentRow,
      state: state,
      sidebarDiagnostics: sidebarDiagnostics
    )

    let detailScroll = element(in: app, identifier: Accessibility.workspaceDetailScrollView)
    let detailCardFrame = frameElement(
      in: app,
      identifier: "\(Accessibility.workspaceDetailCard).frame"
    )
    XCTAssertTrue(
      waitForElement(detailScroll, timeout: Self.uiTimeout),
      """
      Agent detail scroll view should appear after the agent route is selected.
      state=\(state.label)
      """
    )
    XCTAssertTrue(
      waitForElement(detailCardFrame, timeout: Self.uiTimeout),
      """
      Agent detail card frame marker should appear inside the detail scroll viewport.
      state=\(state.label)
      detailScroll=\(detailScroll.frame)
      """
    )

    let detailDiagnostics = agentDetailDiagnostics(
      workspaceWindow: workspaceWindow,
      detailScroll: detailScroll,
      detailCardFrame: detailCardFrame,
      state: state
    )
    XCTAssertGreaterThan(detailScroll.frame.height, 120, detailDiagnostics)
    XCTAssertLessThanOrEqual(
      detailScroll.frame.maxY,
      workspaceWindow.frame.maxY + 1,
      "Agent detail scroll view should be bounded by the workspace window.\n\(detailDiagnostics)"
    )

    XCTAssertGreaterThanOrEqual(
      detailScroll.frame.minY,
      workspaceWindow.frame.minY - 1,
      "Agent detail scroll view should not start above the workspace window.\n\(detailDiagnostics)"
    )

    let roleActionsID = Accessibility.agentDetailRoleActionsDisclosure(agentID)
    let roleActions = element(in: app, identifier: roleActionsID)
    XCTAssertTrue(
      waitForElement(roleActions, timeout: Self.actionTimeout),
      """
      Role actions disclosure should exist inside the agent detail scroll content.
      \(detailDiagnostics)
      """
    )
  }

  func testDecisionDeskUsesNativeSearchFieldAndToolbarFilterMenu() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openWorkspaceWindow(in: app)

    let createRow = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(waitForElement(createRow, timeout: Self.actionTimeout))

    let agentWindow = window(in: app, containing: createRow)
    let toolbar = agentWindow.toolbars.firstMatch
    let nativeSearchField = agentWindow.searchFields.firstMatch
    let filterButton = button(in: app, identifier: Accessibility.workspaceDecisionFiltersMenu)
    let decisionDesk = element(in: app, identifier: Accessibility.workspaceDecisionDesk)
    let legacyScopeMenu = element(
      in: app,
      identifier: Accessibility.decisionsSidebarSearchScopeMenu
    )
    let legacyFilterToggle = element(
      in: app,
      identifier: Accessibility.decisionsSidebarFilterToggle
    )

    XCTAssertTrue(waitForElement(toolbar, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitForElement(nativeSearchField, timeout: Self.fastActionTimeout),
      "Agents decision search should use SwiftUI searchable instead of a custom in-list text field"
    )
    XCTAssertTrue(waitForElement(filterButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(decisionDesk, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      filterButton.isEnabled,
      "Agents decision filter menu should stay enabled when the preview seeds decisions"
    )
    XCTAssertTrue(
      filterButton.label.contains("Severity"),
      "Agents decision toolbar control should expose the severity dimension, not a generic filter label"
    )
    XCTAssertFalse(
      legacyScopeMenu.exists,
      "Agents decision scope menu should come from native search scopes, not a custom sidebar row"
    )
    XCTAssertFalse(
      legacyFilterToggle.exists,
      "Agents decision severity filters should no longer use the old custom sidebar toggle row"
    )

    XCTAssertGreaterThanOrEqual(filterButton.frame.minY, toolbar.frame.minY - 4)
    XCTAssertLessThanOrEqual(filterButton.frame.maxY, toolbar.frame.maxY + 4)
    XCTAssertLessThanOrEqual(
      nativeSearchField.frame.maxY,
      createRow.frame.minY + 2,
      "Agents decision search should render in native sidebar chrome above the list content"
    )
  }

  func testDecisionFilterMenuUpdatesSidebarFilterState() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openWorkspaceWindow(in: app)

    let filterState = element(in: app, identifier: Accessibility.workspaceDecisionFilterState)
    let decisionDesk = element(in: app, identifier: Accessibility.workspaceDecisionDesk)
    XCTAssertTrue(waitForElement(filterState, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(decisionDesk, timeout: Self.fastActionTimeout))
    resetAgentsDecisionSeveritiesIfNeeded(in: app)
    XCTAssertTrue(
      filterState.label.contains("severities=all"),
      "Agents decision filters should start with the full severity set visible"
    )

    openAgentsDecisionFilters(in: app)
    tapButton(in: app, title: "Critical")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        filterState.label.contains("severities=critical")
      },
      """
      Selecting Critical from the toolbar menu should update the agents decision filter state.
      state=\(filterState.label)
      """
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        decisionDesk.label.contains("Severity: Critical")
      },
      """
      Selecting Critical should update the visible Decision Desk summary with the active severity filter.
      label=\(decisionDesk.label)
      """
    )

    openAgentsDecisionFilters(in: app)
    tapButton(in: app, title: "All severities")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        filterState.label.contains("severities=all")
      },
      """
      Resetting the toolbar menu should restore the unfiltered agents decision state.
      state=\(filterState.label)
      """
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        decisionDesk.label.contains("Severity:") == false
      },
      """
      Clearing severity filters should remove the explicit severity summary from the Decision Desk row.
      label=\(decisionDesk.label)
      """
    )
  }

  private func ensureAgentDetailSelection(
    in app: XCUIApplication,
    agentID: String,
    agentRow: XCUIElement,
    state: XCUIElement,
    sidebarDiagnostics: String
  ) {
    let agentSelectionMarker = "selection=agent:\(agentID)"
    let agentRowIdentifier = Accessibility.agentTuiExternalTab(agentID)
    let selectionFlipped = waitUntil(timeout: Self.actionTimeout) {
      state.label.contains(agentSelectionMarker)
    }
    if !selectionFlipped {
      tapViaCoordinate(in: app, element: agentRow)
      if !waitUntil(
        timeout: Self.actionTimeout,
        condition: {
          state.label.contains(agentSelectionMarker)
        })
      {
        _ = clickVisibleFrameMarker(in: app, identifier: agentRowIdentifier)
      }
    }
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        state.label.contains(agentSelectionMarker)
      },
      """
      Tapping the worker row should switch the workspace selection to the agent route.
      state=\(state.label)
      \(sidebarDiagnostics)
      """
    )
  }

  private func agentDetailDiagnostics(
    workspaceWindow: XCUIElement,
    detailScroll: XCUIElement,
    detailCardFrame: XCUIElement,
    state: XCUIElement
  ) -> String {
    """
    workspaceWindow: \(workspaceWindow.frame)
    detailScroll: \(detailScroll.frame)
    detailCard: \(detailCardFrame.frame)
    state: \(state.label)
    """
  }
}
