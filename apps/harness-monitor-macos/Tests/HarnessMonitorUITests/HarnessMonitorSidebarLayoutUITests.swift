import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSidebarLayoutUITests: HarnessMonitorUITestCase {
  func testSidebarContentStartsBelowToolbarChrome() throws {
    let app = launch(mode: "preview")
    let window = mainWindow(in: app)
    let sidebarContent = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let toolbar = window.toolbars.firstMatch

    XCTAssertTrue(waitForElement(window, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sidebarContent, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(searchField, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(toolbar, timeout: Self.fastActionTimeout))

    let toolbarOffset = sidebarContent.frame.minY - window.frame.minY
    let diagnostics = """
      window: \(window.frame)
      toolbar: \(toolbar.frame)
      sidebar: \(sidebarContent.frame)
      searchField: \(searchField.frame)
      toolbarOffset: \(toolbarOffset)
      """
    XCTAssertGreaterThan(toolbarOffset, 40)
    XCTAssertLessThan(toolbarOffset, 84, diagnostics)
  }

  func testMainWindowUsesNativeToolbarChromeWithoutCustomBaselineDivider() throws {
    let app = launch(mode: "preview")
    let toolbarDivider = frameElement(in: app, identifier: Accessibility.toolbarBaselineDivider)

    XCTAssertFalse(
      toolbarDivider.exists,
      """
      Expected the main window to rely on native Liquid Glass toolbar chrome \
      instead of a custom baseline divider
      """
    )
  }

  func testSidebarCheckoutHeaderFillsAvailableWidth() throws {
    let app = launch(mode: "preview")
    let sidebarShell = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let checkoutHeader = frameElement(in: app, identifier: Accessibility.previewCheckoutHeaderFrame)
    let sessionCard = frameElement(in: app, identifier: Accessibility.previewSessionRowFrame)

    XCTAssertTrue(waitForElement(sidebarShell, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(checkoutHeader, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionCard, timeout: Self.fastActionTimeout))

    let leadingInset = checkoutHeader.frame.minX - sidebarShell.frame.minX
    let trailingInset = sidebarShell.frame.maxX - checkoutHeader.frame.maxX

    XCTAssertEqual(sessionCard.frame.minX, checkoutHeader.frame.minX, accuracy: 2)
    XCTAssertEqual(sessionCard.frame.maxX, checkoutHeader.frame.maxX, accuracy: 2)
    XCTAssertGreaterThanOrEqual(leadingInset, 0)
    XCTAssertGreaterThanOrEqual(trailingInset, 0)
    XCTAssertLessThanOrEqual(leadingInset, 24)
    XCTAssertLessThanOrEqual(trailingInset, 24)
    XCTAssertEqual(leadingInset, trailingInset, accuracy: 8)
    XCTAssertGreaterThan(checkoutHeader.frame.width, sidebarShell.frame.width - 48)
  }

  func testToolbarSearchAndFilterControlsAreVisible() throws {
    let app = launch(mode: "preview")
    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let filterMenu = button(in: app, identifier: Accessibility.sidebarFilterMenu)
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)

    XCTAssertTrue(waitForElement(searchField, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filterMenu, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filterState, timeout: Self.fastActionTimeout))
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

  func testToolbarFilterMenuAppliesStatusAndResetFlow() throws {
    let app = launch(mode: "preview")
    let filterMenu = button(in: app, identifier: Accessibility.sidebarFilterMenu)
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)
    let emptyState = frameElement(in: app, identifier: Accessibility.sidebarEmptyStateFrame)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(waitForElement(filterMenu, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(filterState, timeout: Self.fastActionTimeout))

    tapButton(in: app, identifier: Accessibility.sidebarFilterMenu)
    tapButton(in: app, title: "Ended")
    XCTAssertTrue(waitForElement(emptyState, timeout: Self.fastActionTimeout))
    XCTAssertTrue(filterState.label.contains("status=ended"))

    tapButton(in: app, identifier: Accessibility.sidebarFilterMenu)
    tapButton(in: app, title: "Clear Filters")

    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(filterState.label.contains("status=all"))
    XCTAssertTrue(filterState.label.contains("sort=recentActivity"))
  }

  func testCheckoutHeaderOnlyTogglesSessionDisclosure() throws {
    let app = launch(mode: "preview")
    let checkoutHeader = element(in: app, identifier: Accessibility.previewCheckoutHeader)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(waitForElement(checkoutHeader, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))

    tapPreviewSession(in: app)

    let observeButton = button(in: app, identifier: Accessibility.observeSummaryButton)
    XCTAssertTrue(waitForElement(observeButton, timeout: Self.fastActionTimeout))

    toggleCheckoutDisclosure(
      of: checkoutHeader,
      in: app
    ) {
      !sessionRow.exists
    }

    XCTAssertTrue(waitForElement(observeButton, timeout: Self.fastActionTimeout))
    XCTAssertFalse(sessionRow.exists)

    toggleCheckoutDisclosure(
      of: checkoutHeader,
      in: app
    ) {
      sessionRow.exists
    }

    XCTAssertTrue(waitForElement(observeButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))
  }

  func testSelectedSessionChromeFillsFullSessionRowHeight() throws {
    let app = launch(mode: "preview")
    let sessionRow = previewSessionTrigger(in: app)
    let sessionRowFrame = frameElement(in: app, identifier: Accessibility.previewSessionRowFrame)

    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionRowFrame, timeout: Self.fastActionTimeout))

    tapPreviewSession(in: app)

    let observeButton = button(in: app, identifier: Accessibility.observeSummaryButton)
    XCTAssertTrue(waitForElement(observeButton, timeout: Self.fastActionTimeout))

    let selectedFrame = frameElement(
      in: app,
      identifier: Accessibility.previewSessionRowSelectionFrame
    )
    XCTAssertTrue(waitForElement(selectedFrame, timeout: Self.fastActionTimeout))
    XCTAssertEqual(selectedFrame.frame.minY, sessionRowFrame.frame.minY, accuracy: 2)
    XCTAssertEqual(selectedFrame.frame.height, sessionRowFrame.frame.height, accuracy: 2)
  }

  private func tapTrailingEdge(
    of element: XCUIElement,
    in app: XCUIApplication
  ) {
    let window = window(in: app, containing: element)
    XCTAssertTrue(waitForElement(window, timeout: Self.fastActionTimeout))

    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    origin
      .withOffset(
        CGVector(
          dx: element.frame.maxX - window.frame.minX - 8,
          dy: element.frame.midY - window.frame.minY
        )
      )
      .tap()
  }

  private func toggleCheckoutDisclosure(
    of element: XCUIElement,
    in app: XCUIApplication,
    until condition: @escaping () -> Bool
  ) {
    tapTrailingEdge(of: element, in: app)
    if waitUntil(timeout: 0.2, condition: condition) {
      return
    }

    tapTrailingEdge(of: element, in: app)
    XCTAssertTrue(waitUntil(timeout: Self.fastActionTimeout, condition: condition))
  }
}
