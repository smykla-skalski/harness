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
    let statusPicker = element(in: app, identifier: Accessibility.sidebarStatusPicker)
    let focusPicker = element(in: app, identifier: Accessibility.sidebarFocusPicker)
    let sortPicker = element(in: app, identifier: Accessibility.sidebarSortPicker)
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)

    XCTAssertTrue(waitForElement(searchField, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(statusPicker, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(focusPicker, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sortPicker, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filterState, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        !filterState.label.isEmpty && filterState.label.contains("sort=")
      }
    )
  }

  func testDashboardLandingDefersSidebarFilterControlsUntilSearchBegins() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )
    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let searchState = element(in: app, identifier: Accessibility.sidebarSearchState)
    let sidebarShell = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)

    XCTAssertTrue(waitForElement(searchField, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(searchState, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sidebarShell, timeout: Self.fastActionTimeout))
    XCTAssertFalse(
      sidebarFilterControl(in: app).exists,
      "Dashboard landing should not pay filter chrome cost until sidebar search is engaged"
    )

    tapElement(in: app, identifier: Accessibility.sidebarSearchField)
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        let filterMenu = self.sidebarFilterControl(in: app)
        return searchState.label.contains("visible=true")
          && filterMenu.exists
          && !filterMenu.frame.isEmpty
      },
      """
      Focusing the native sidebar search field should reveal the sidebar filter controls.
      searchState=\(searchState.label)
      searchFieldFrame=\(searchField.frame)
      sidebarShellFrame=\(sidebarShell.frame)
      filterDiagnostics=\(sidebarFilterControlDiagnostics(in: app))
      """
    )
  }

  func testSidebarUsesNativeSearchFieldWithFilterMenuBelowIt() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let sidebarShell = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let nativeSearchField = mainWindow(in: app).searchFields.firstMatch
    let statusPicker = element(in: app, identifier: Accessibility.sidebarStatusPicker)

    XCTAssertTrue(waitForElement(sidebarShell, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitForElement(nativeSearchField, timeout: Self.fastActionTimeout),
      "Sidebar search should use SwiftUI searchable instead of a custom text field"
    )
    XCTAssertTrue(waitForElement(statusPicker, timeout: Self.fastActionTimeout))

    XCTAssertGreaterThanOrEqual(nativeSearchField.frame.minX, sidebarShell.frame.minX - 8)
    XCTAssertLessThanOrEqual(nativeSearchField.frame.maxX, sidebarShell.frame.maxX + 8)
    XCTAssertGreaterThanOrEqual(
      statusPicker.frame.minY,
      nativeSearchField.frame.maxY - 2,
      "Sidebar filters should live below the native search field inside the sidebar"
    )
    XCTAssertLessThanOrEqual(statusPicker.frame.maxY, sidebarShell.frame.maxY + 8)
  }

  func testSidebarFilterControlsLiveInsideScrollableSidebarContent() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let sessionList = frameElement(in: app, identifier: Accessibility.sidebarSessionListContent)
    let filtersCard = frameElement(in: app, identifier: Accessibility.sidebarFiltersCardFrame)

    XCTAssertTrue(waitForElement(sessionList, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filtersCard, timeout: Self.fastActionTimeout))

    XCTAssertGreaterThanOrEqual(
      filtersCard.frame.minY,
      sessionList.frame.minY - 2,
      "Sidebar filters should be rendered inside the scrollable sidebar content"
    )
    XCTAssertLessThanOrEqual(
      filtersCard.frame.maxY,
      sessionList.frame.maxY + 2,
      "Sidebar filters should stay inside the sidebar list bounds"
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
    let statusPicker = element(in: app, identifier: Accessibility.sidebarStatusPicker)
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)
    let emptyState = frameElement(in: app, identifier: Accessibility.sidebarEmptyStateFrame)

    XCTAssertTrue(waitForElement(statusPicker, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filterState, timeout: Self.fastActionTimeout))

    tapElement(in: app, identifier: Accessibility.sidebarStatusPicker)
    tapButton(in: app, title: "Ended")
    XCTAssertTrue(waitForElement(emptyState, timeout: Self.fastActionTimeout))
    XCTAssertTrue(filterState.label.contains("status=ended"))

    tapButton(in: app, identifier: Accessibility.sidebarClearFiltersButton)

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
}
