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
    XCTAssertGreaterThan(toolbarOffset, 72, diagnostics)
    XCTAssertLessThan(toolbarOffset, 120, diagnostics)
    XCTAssertGreaterThanOrEqual(
      sidebarContent.frame.minY,
      searchField.frame.maxY,
      "Sidebar content should begin below the native search field"
    )
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

  func testMainWindowUsesSystemManagedToolbarBackground() throws {
    let app = launch(mode: "preview")
    let toolbarChromeState = element(in: app, identifier: Accessibility.toolbarChromeState)

    XCTAssertTrue(waitForElement(toolbarChromeState, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        toolbarChromeState.label.contains("toolbarBackground=automatic")
      },
      """
      Expected the main window to keep the system-managed toolbar background \
      instead of opting out with a hidden toolbar background
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

  func testCheckoutHeaderKeepsStableChevronDisclosureGlyph() throws {
    let app = launch(mode: "preview")
    let checkoutHeader = element(in: app, identifier: Accessibility.previewCheckoutHeader)
    let glyph = element(in: app, identifier: Accessibility.previewCheckoutHeaderGlyph)

    XCTAssertTrue(waitForElement(checkoutHeader, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitForElement(glyph, timeout: Self.fastActionTimeout),
      "Checkout disclosure header should publish its glyph state for UI regression coverage"
    )
    XCTAssertEqual(glyph.label, "chevron.down")

    toggleCheckoutDisclosure(
      of: checkoutHeader,
      in: app
    ) {
      glyph.label == "chevron.right"
    }

    XCTAssertEqual(glyph.label, "chevron.right")

    toggleCheckoutDisclosure(
      of: checkoutHeader,
      in: app
    ) {
      glyph.label == "chevron.down"
    }

    XCTAssertEqual(glyph.label, "chevron.down")
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

  func testSidebarSessionRowPublishesCompactStatIconProbes() throws {
    let app = launch(mode: "preview")
    let agentStat = element(in: app, identifier: Accessibility.previewSessionRowAgentStat)
    let taskStat = element(in: app, identifier: Accessibility.previewSessionRowTaskStat)

    XCTAssertTrue(
      waitForElement(agentStat, timeout: Self.fastActionTimeout),
      "Preview session row should publish the agent stat icon probe"
    )
    XCTAssertTrue(
      waitForElement(taskStat, timeout: Self.fastActionTimeout),
      "Preview session row should publish the task stat icon probe"
    )
    XCTAssertEqual(agentStat.label, "person.2.fill")
    XCTAssertEqual(taskStat.label, "arrow.triangle.2.circlepath")
  }

  func testSelectedSidebarSessionOffersContextMenuActions() throws {
    let app = launch(mode: "preview")
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))

    tapPreviewSession(in: app)
    sessionRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

    let bookmarkItem = app.menuItems["Bookmark"].firstMatch
    let copySessionIDItem = app.menuItems["Copy Session ID"].firstMatch

    XCTAssertTrue(
      bookmarkItem.waitForExistence(timeout: Self.fastActionTimeout),
      "Selected sidebar rows should keep the native bookmark context menu action"
    )
    XCTAssertTrue(
      copySessionIDItem.waitForExistence(timeout: Self.fastActionTimeout),
      "Selected sidebar rows should keep the native copy context menu action"
    )

    app.typeKey(.escape, modifierFlags: [])
  }

  func testSidebarSessionRowKeepsStatClusterAndTimestampSeparatedAtLargeTextSize() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [HarnessMonitorSettingsUITestKeys.textSizeOverride: "6"]
    )
    let sidebarToggle = sidebarToggleButton(in: app)
    let sidebarShellQuery = app.otherElements
      .matching(identifier: Accessibility.sidebarShellFrame)
    let sidebarShell = sidebarShellQuery.firstMatch
    let sessionRowFrame = frameElement(in: app, identifier: Accessibility.previewSessionRowFrame)
    let statsFrame = frameElement(in: app, identifier: Accessibility.previewSessionRowStatsFrame)
    let lastActivityFrame = frameElement(
      in: app,
      identifier: Accessibility.previewSessionRowLastActivityFrame
    )

    XCTAssertTrue(waitForElement(sidebarToggle, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sidebarShell, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionRowFrame, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(statsFrame, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(lastActivityFrame, timeout: Self.fastActionTimeout))
    let initialSidebarWidth = sidebarShell.frame.width
    XCTAssertGreaterThan(initialSidebarWidth, 200)

    sidebarToggle.tap()

    XCTAssertTrue(
      waitUntil {
        guard let collapsedSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return true
        }
        return collapsedSidebar.frame.width < max(120, initialSidebarWidth * 0.5)
      }
    )

    let diagnostics = """
      row: \(sessionRowFrame.frame)
      stats: \(statsFrame.frame)
      lastActivity: \(lastActivityFrame.frame)
      """

    XCTAssertGreaterThanOrEqual(statsFrame.frame.minX, sessionRowFrame.frame.minX, diagnostics)
    XCTAssertLessThanOrEqual(statsFrame.frame.maxX, sessionRowFrame.frame.maxX, diagnostics)
    XCTAssertGreaterThanOrEqual(
      lastActivityFrame.frame.minX,
      sessionRowFrame.frame.minX,
      diagnostics
    )
    XCTAssertLessThanOrEqual(lastActivityFrame.frame.maxX, sessionRowFrame.frame.maxX, diagnostics)
    XCTAssertLessThan(statsFrame.frame.maxX, lastActivityFrame.frame.minX, diagnostics)
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
