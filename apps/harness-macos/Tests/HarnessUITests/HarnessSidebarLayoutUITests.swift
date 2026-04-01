import XCTest

private typealias Accessibility = HarnessUITestAccessibility

@MainActor
final class HarnessSidebarLayoutUITests: HarnessUITestCase {
  func testSidebarDaemonBadgesShareWidth() throws {
    let app = launch(mode: "empty")
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let daemonCard = frameElement(in: app, identifier: Accessibility.daemonCardFrame)

    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(daemonCard.waitForExistence(timeout: Self.uiTimeout))
    assertFillsColumn(
      child: daemonCard,
      in: sidebarRoot,
      expectedHorizontalInset: 22,
      tolerance: 12
    )
    XCTAssertLessThan(daemonCard.frame.height, 360)
  }

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

  func testSidebarProjectHeaderFillsAvailableWidth() throws {
    let app = launch(mode: "preview")
    let sessionList = frameElement(in: app, identifier: Accessibility.sidebarSessionListContent)
    let projectHeader = frameElement(in: app, identifier: Accessibility.previewProjectHeaderFrame)
    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionList.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(projectHeader.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    assertFillsColumn(child: projectHeader, in: sessionList, expectedHorizontalInset: 0, tolerance: 10)
    assertFillsColumn(child: sessionRow, in: sessionList, expectedHorizontalInset: 0, tolerance: 10)
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
      additionalEnvironment: ["HARNESS_PREVIEW_FIXTURE_SET": "overflow"]
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
    let blockedChip = focusChip(in: app, identifier: Accessibility.blockedChip, title: "Blocked")
    XCTAssertTrue(blockedChip.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(blockedChip.value as? String, "not selected")
    tapButton(in: app, identifier: Accessibility.blockedChip)
    XCTAssertTrue(
      waitUntil {
        let refreshedChip = self.button(in: app, identifier: Accessibility.blockedChip)
        return refreshedChip.value as? String == "selected"
      }
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.sidebarClearFiltersButton).waitForExistence(
        timeout: Self.uiTimeout
      )
    )
  }
}
