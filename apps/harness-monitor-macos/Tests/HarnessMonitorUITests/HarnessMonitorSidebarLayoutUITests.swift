import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSidebarLayoutUITests: HarnessMonitorUITestCase {
  func testSidebarContentStartsBelowToolbarChrome() throws {
    let app = launch(mode: "preview")
    let window = mainWindow(in: app)
    let sidebarContent = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebarContent.waitForExistence(timeout: Self.actionTimeout))

    let toolbarOffset = sidebarContent.frame.minY - window.frame.minY
    XCTAssertGreaterThan(toolbarOffset, 40)
    XCTAssertLessThan(toolbarOffset, 84)
  }

  func testMainWindowUsesNativeToolbarChromeWithoutCustomBaselineDivider() throws {
    let app = launch(mode: "preview")
    let toolbarDivider = frameElement(in: app, identifier: Accessibility.toolbarBaselineDivider)

    XCTAssertFalse(
      toolbarDivider.waitForExistence(timeout: Self.actionTimeout),
      """
      Expected the main window to rely on native Liquid Glass toolbar chrome \
      instead of a custom baseline divider
      """
    )
  }

  func testSidebarProjectHeaderFillsAvailableWidth() throws {
    let app = launch(mode: "preview")
    let sidebarShell = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let projectHeader = frameElement(in: app, identifier: Accessibility.previewProjectHeaderFrame)
    let sessionCard = frameElement(in: app, identifier: Accessibility.previewSessionRowFrame)

    XCTAssertTrue(sidebarShell.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(projectHeader.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionCard.waitForExistence(timeout: Self.actionTimeout))

    XCTAssertEqual(projectHeader.frame.minX, sidebarShell.frame.minX, accuracy: 8)
    XCTAssertEqual(projectHeader.frame.maxX, sidebarShell.frame.maxX, accuracy: 8)
    XCTAssertEqual(sessionCard.frame.minX, projectHeader.frame.minX, accuracy: 2)
    XCTAssertEqual(sessionCard.frame.maxX, projectHeader.frame.maxX, accuracy: 2)
  }

  func testToolbarSearchAndFilterControlsAreVisible() throws {
    let app = launch(mode: "preview")
    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let filterMenu = button(in: app, identifier: Accessibility.sidebarFilterMenu)
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)

    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterMenu.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterState.label.contains("status=active"))
  }

  func testSidebarScrollMovesSessionRowsWhenContentOverflows() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "overflow"]
    )
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let sessionList = frameElement(in: app, identifier: Accessibility.sidebarSessionListContent)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionList.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
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

  func testToolbarFilterMenuAppliesStatusAndResetFlow() throws {
    let app = launch(mode: "preview")
    let filterMenu = button(in: app, identifier: Accessibility.sidebarFilterMenu)
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)
    let emptyState = frameElement(in: app, identifier: Accessibility.sidebarEmptyStateFrame)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(filterMenu.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterState.waitForExistence(timeout: Self.actionTimeout))

    tapButton(in: app, identifier: Accessibility.sidebarFilterMenu)
    tapButton(in: app, title: "Ended")
    XCTAssertTrue(emptyState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterState.label.contains("status=ended"))

    tapButton(in: app, identifier: Accessibility.sidebarFilterMenu)
    tapButton(in: app, identifier: Accessibility.sidebarClearFiltersButton)

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterState.label.contains("status=active"))
    XCTAssertTrue(filterState.label.contains("sort=recentActivity"))
  }
}
