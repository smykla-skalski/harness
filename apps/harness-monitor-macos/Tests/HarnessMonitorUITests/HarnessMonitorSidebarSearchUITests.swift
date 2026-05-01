import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension HarnessMonitorSidebarLayoutUITests {
  func testSidebarSearchAndFilterControlsAreVisible() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let filterButton = sidebarFilterControl(in: app)
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)

    XCTAssertTrue(waitForElement(searchField, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filterButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filterState, timeout: Self.fastActionTimeout))

    openSidebarFilters(in: app)
    XCTAssertTrue(waitForElement(element(in: app, title: "Ended"), timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitForElement(element(in: app, title: "Open Work"), timeout: Self.fastActionTimeout)
    )
    XCTAssertTrue(
      waitForElement(element(in: app, title: "Recent Activity"), timeout: Self.fastActionTimeout)
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        !filterState.label.isEmpty && filterState.label.contains("sort=")
      }
    )
  }

  func testDashboardLandingPlacesSidebarFiltersInToolbarChrome() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )
    let filterButton = sidebarFilterControl(in: app)
    let toolbar = mainWindow(in: app).toolbars.firstMatch
    let sessionList = frameElement(in: app, identifier: Accessibility.sidebarSessionListContent)

    XCTAssertTrue(waitForElement(filterButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(toolbar, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionList, timeout: Self.fastActionTimeout))
    XCTAssertGreaterThanOrEqual(filterButton.frame.minY, toolbar.frame.minY - 4)
    XCTAssertLessThanOrEqual(filterButton.frame.maxY, toolbar.frame.maxY + 4)
    XCTAssertLessThanOrEqual(
      filterButton.frame.maxY,
      sessionList.frame.minY + 2,
      "Sidebar filters should live in toolbar chrome above the scrollable sidebar content"
    )
  }

  func testSidebarUsesNativeSearchFieldWithToolbarFilterMenu() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let window = mainWindow(in: app)
    let sidebarShell = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let nativeSearchField = mainWindow(in: app).searchFields.firstMatch
    let filterButton = sidebarFilterControl(in: app)
    let toolbar = window.toolbars.firstMatch

    XCTAssertTrue(waitForElement(sidebarShell, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitForElement(nativeSearchField, timeout: Self.fastActionTimeout),
      "Sidebar search should use SwiftUI searchable instead of a custom text field"
    )
    XCTAssertTrue(waitForElement(filterButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(toolbar, timeout: Self.fastActionTimeout))

    XCTAssertGreaterThanOrEqual(nativeSearchField.frame.minX, sidebarShell.frame.minX - 8)
    XCTAssertLessThanOrEqual(nativeSearchField.frame.maxX, sidebarShell.frame.maxX + 8)
    XCTAssertGreaterThanOrEqual(
      filterButton.frame.minY,
      toolbar.frame.minY - 4,
      "Sidebar filters should render inside native toolbar chrome"
    )
    XCTAssertLessThanOrEqual(filterButton.frame.maxY, toolbar.frame.maxY + 4)
  }

  func testSidebarFilterControlsLiveOutsideScrollableSidebarContent() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let sessionList = frameElement(in: app, identifier: Accessibility.sidebarSessionListContent)
    let filtersCard = sidebarFilterControl(in: app)

    XCTAssertTrue(waitForElement(sessionList, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filtersCard, timeout: Self.fastActionTimeout))

    XCTAssertLessThanOrEqual(
      filtersCard.frame.maxY,
      sessionList.frame.minY + 2,
      "Sidebar filters should stay in toolbar chrome, not the sidebar list bounds"
    )
  }

  func testSidebarSearchFieldIsRenderedInsideSidebarChrome() throws {
    let app = launch(mode: "preview")
    let window = mainWindow(in: app)
    let sidebarShell = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let searchField = mainWindow(in: app).searchFields.firstMatch
    let toolbar = window.toolbars.firstMatch

    XCTAssertTrue(waitForElement(window, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sidebarShell, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitForElement(searchField, timeout: Self.fastActionTimeout),
      "Sidebar search should be rendered by SwiftUI searchable inside the sidebar chrome"
    )
    XCTAssertTrue(waitForElement(toolbar, timeout: Self.fastActionTimeout))

    XCTAssertGreaterThanOrEqual(searchField.frame.minX, sidebarShell.frame.minX - 8)
    XCTAssertLessThanOrEqual(searchField.frame.maxX, sidebarShell.frame.maxX + 8)
    XCTAssertGreaterThanOrEqual(searchField.frame.minY, toolbar.frame.maxY - 4)
    XCTAssertLessThanOrEqual(searchField.frame.maxY, sidebarShell.frame.minY)
  }

  func testSidebarScrollMovesSessionRowsWhenContentOverflows() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "overflow"]
    )
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let sessionList = frameElement(in: app, identifier: Accessibility.sidebarSessionListContent)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(waitForElement(sidebarRoot, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionList, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))
    let initialMinY = sessionRow.frame.minY

    for _ in 0..<8 {
      dragUp(in: app, element: sidebarRoot, distanceRatio: 0.44)
      if sessionRow.frame.minY < initialMinY - 24 {
        break
      }
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        sessionRow.frame.minY < initialMinY - 24
      }
    )
  }

  func testSidebarSearchControlsApplyStatusAndResetFlow() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)
    let emptyState = frameElement(in: app, identifier: Accessibility.sidebarEmptyStateFrame)

    XCTAssertTrue(waitForElement(sidebarFilterControl(in: app), timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filterState, timeout: Self.fastActionTimeout))

    openSidebarFilters(in: app)
    tapButton(in: app, title: "Ended")
    XCTAssertTrue(waitForElement(emptyState, timeout: Self.fastActionTimeout))
    XCTAssertTrue(filterState.label.contains("status=ended"))

    openSidebarFilters(in: app)
    tapButton(in: app, title: "Clear Filters")

    let didResetFilterState = waitUntil(timeout: Self.fastActionTimeout) {
      filterState.label.contains("status=all")
        && filterState.label.contains("sort=recentActivity")
    }
    let didRestoreSession = waitUntil(timeout: Self.fastActionTimeout) {
      self.previewSessionTrigger(in: app).exists
    }

    if !didRestoreSession {
      attachWindowScreenshot(in: app, named: "sidebar-filter-reset-missing-session")
      attachAppHierarchy(in: app, named: "sidebar-filter-reset-missing-session-hierarchy")
      let listState = element(in: app, identifier: Accessibility.sidebarSessionListState)
      let diagnostics = """
        didResetFilterState=\(didResetFilterState)
        filterState=\(filterState.label)
        listState=\(listState.label)
        emptyStateExists=\(emptyState.exists)
        sessionRowExists=\(previewSessionTrigger(in: app).exists)
        """
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "sidebar-filter-reset-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertTrue(
      didRestoreSession,
      "Clear Filters should restore the preview session row"
    )
    XCTAssertTrue(filterState.label.contains("status=all"))
    XCTAssertTrue(filterState.label.contains("sort=recentActivity"))
  }

  private func openSidebarFilters(in app: XCUIApplication) {
    let filterButton = sidebarFilterControl(in: app)
    XCTAssertTrue(
      waitForElement(filterButton, timeout: Self.fastActionTimeout),
      "Sidebar filter button should exist before opening the menu"
    )
    app.activate()
    if let coordinate = centerCoordinate(in: app, for: filterButton) {
      coordinate.click()
    } else if filterButton.isHittable {
      filterButton.click()
    } else {
      XCTFail("Failed to resolve the actual sidebar filter button")
      return
    }

    let statusOption = element(in: app, title: "Ended")
    guard waitForElement(statusOption, timeout: Self.fastActionTimeout) else {
      attachWindowScreenshot(in: app, named: "sidebar-filter-open-failure")
      attachAppHierarchy(in: app, named: "sidebar-filter-open-failure-hierarchy")
      let diagnostics = sidebarFilterControlDiagnostics(in: app)
        .replacingOccurrences(of: "\n", with: " | ")
      XCTFail(
        """
        Expected sidebar filter menu options after opening the toolbar filter control. \
        diagnostics=\(diagnostics)
        """
      )
      return
    }
  }
}
