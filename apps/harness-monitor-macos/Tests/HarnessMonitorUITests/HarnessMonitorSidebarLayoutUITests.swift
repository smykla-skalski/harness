import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSidebarLayoutUITests: HarnessMonitorUITestCase {
  func testSidebarContentStartsBelowToolbarChrome() throws {
    let app = launch(mode: "preview")
    let window = mainWindow(in: app)
    let sidebarContent = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let daemonCard = frameElement(in: app, identifier: Accessibility.daemonCardFrame)

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarContent.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(daemonCard.waitForExistence(timeout: Self.uiTimeout))

    let toolbarOffset = sidebarContent.frame.minY - window.frame.minY
    XCTAssertGreaterThan(toolbarOffset, 40)
    XCTAssertLessThan(toolbarOffset, 84)
    XCTAssertGreaterThanOrEqual(daemonCard.frame.minY - sidebarContent.frame.minY, 0)
    XCTAssertLessThan(daemonCard.frame.minY - sidebarContent.frame.minY, 28)
  }

  func testToolbarBaselineDividerStartsAtSidebarBoundary() throws {
    let app = launch(mode: "preview")
    let window = mainWindow(in: app)
    let sidebarContent = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let toolbarDivider = frameElement(in: app, identifier: Accessibility.toolbarBaselineDivider)
    let toolbar = window.toolbars.firstMatch

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarContent.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(toolbarDivider.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.uiTimeout))

    XCTAssertEqual(toolbarDivider.frame.minX, sidebarContent.frame.maxX, accuracy: 6)
    XCTAssertEqual(toolbarDivider.frame.maxX, window.frame.maxX, accuracy: 6)

    let dividerTopOffset = toolbarDivider.frame.minY - window.frame.minY
    let toolbarBottomOffset = toolbar.frame.maxY - window.frame.minY

    XCTAssertGreaterThanOrEqual(dividerTopOffset, toolbarBottomOffset - 4)
    XCTAssertLessThanOrEqual(dividerTopOffset, toolbarBottomOffset + 12)
  }

  func testSidebarProjectHeaderFillsAvailableWidth() throws {
    let app = launch(mode: "preview")
    let filtersCard = frameElement(in: app, identifier: Accessibility.sidebarFiltersCardFrame)
    let projectHeader = frameElement(in: app, identifier: Accessibility.previewProjectHeaderFrame)

    XCTAssertTrue(filtersCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(projectHeader.waitForExistence(timeout: Self.uiTimeout))

    XCTAssertEqual(projectHeader.frame.minX, filtersCard.frame.minX)
    XCTAssertEqual(projectHeader.frame.maxX, filtersCard.frame.maxX)

    let headerSpacing = projectHeader.frame.minY - filtersCard.frame.maxY
    XCTAssertGreaterThanOrEqual(headerSpacing, 0)
    XCTAssertLessThanOrEqual(headerSpacing, 32)
  }

  func testSidebarSessionCardMatchesFiltersCardWidth() throws {
    let app = launch(mode: "preview")
    let filtersCard = frameElement(in: app, identifier: Accessibility.sidebarFiltersCardFrame)
    let sessionCard = frameElement(in: app, identifier: Accessibility.previewSessionRowFrame)

    XCTAssertTrue(filtersCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(sessionCard.frame.minX, filtersCard.frame.minX)
    XCTAssertEqual(sessionCard.frame.maxX, filtersCard.frame.maxX)
  }

  func testSidebarFilterSliceFillsColumnAndStartsUnfiltered() throws {
    let app = launch(mode: "preview")
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let filtersCard = app.staticTexts["Search & Filters"]
    let searchField = element(in: app, identifier: Accessibility.sidebarSearchField)
    let clearButton = element(in: app, identifier: Accessibility.sidebarClearFiltersButton)

    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(filtersCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(clearButton.exists)
    XCTAssertTrue(sidebarRoot.exists)
    XCTAssertTrue(filtersCard.exists)
  }

  func testSidebarScrollMovesSessionRowsWhenContentOverflows() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "overflow"]
    )
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let sessionList = frameElement(in: app, identifier: Accessibility.sidebarSessionListContent)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionList.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    let initialMinY = sessionRow.frame.minY

    for _ in 0..<8 {
      dragUp(in: app, element: sidebarRoot, distanceRatio: 0.44)
      if sessionRow.frame.minY < initialMinY - 24 {
        break
      }
    }

    XCTAssertTrue(
      waitUntil {
        sessionRow.frame.minY < initialMinY - 24
      }
    )
  }

  func testFocusFilterSelectionTogglesAccessibilityState() throws {
    let app = launch(mode: "preview")
    let blockedSegment = button(in: app, identifier: Accessibility.blockedChip)
    XCTAssertTrue(blockedSegment.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.blockedChip)
    XCTAssertTrue(
      app.staticTexts["1 visible of 1"].waitForExistence(timeout: Self.uiTimeout)
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.sidebarClearFiltersButton).waitForExistence(
        timeout: Self.uiTimeout
      )
    )
  }

  func testStatusFilterSelectionTogglesAccessibilityState() throws {
    let app = launch(mode: "preview")
    let endedSegment = element(in: app, identifier: Accessibility.endedFilterButton)

    XCTAssertTrue(endedSegment.waitForExistence(timeout: Self.uiTimeout))

    tapButton(in: app, title: "Ended")

    XCTAssertTrue(
      frameElement(in: app, identifier: Accessibility.sidebarEmptyStateFrame).waitForExistence(
        timeout: Self.uiTimeout
      )
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.sidebarClearFiltersButton).waitForExistence(
        timeout: Self.uiTimeout
      )
    )
  }

  func testSidebarEmptyStateStartsDirectlyBelowFiltersCard() throws {
    let app = launch(mode: "preview")
    let filtersCard = frameElement(in: app, identifier: Accessibility.sidebarFiltersCardFrame)
    let emptyState = frameElement(in: app, identifier: Accessibility.sidebarEmptyStateFrame)
    XCTAssertTrue(filtersCard.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.idleChip)
    XCTAssertTrue(emptyState.waitForExistence(timeout: Self.uiTimeout))

    let emptyStateSpacing = emptyState.frame.minY - filtersCard.frame.maxY
    XCTAssertGreaterThanOrEqual(emptyStateSpacing, 0)
    XCTAssertLessThan(emptyStateSpacing, 32)
  }
}
