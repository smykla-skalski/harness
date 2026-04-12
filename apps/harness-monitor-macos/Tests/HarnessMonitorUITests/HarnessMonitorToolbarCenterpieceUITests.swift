import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

private struct ToolbarCenterpieceMetrics {
  let toolbarFrame: CGRect
  let centerpieceFrame: CGRect
  let metricsFrame: CGRect
  let statusTickerFrame: CGRect
  let statusTickerContentFrame: CGRect
  let centerOffset: CGFloat
  let verticalOffset: CGFloat
  let leadingInset: CGFloat
  let interiorGap: CGFloat
  let trailingInset: CGFloat
  let statusLeadingInset: CGFloat
  let statusTrailingInset: CGFloat

  var diagnostics: String {
    """
    toolbar: \(toolbarFrame)
    centerpieceFrame: \(centerpieceFrame)
    metricsFrame: \(metricsFrame)
    statusTicker: \(statusTickerFrame)
    statusTickerContent: \(statusTickerContentFrame)
    centerOffset: \(centerOffset)
    verticalOffset: \(verticalOffset)
    leadingInset: \(leadingInset)
    interiorGap: \(interiorGap)
    trailingInset: \(trailingInset)
    statusLeadingInset: \(statusLeadingInset)
    statusTrailingInset: \(statusTrailingInset)
    """
  }
}

final class HarnessMonitorToolbarCenterpieceUITests: HarnessMonitorUITestCase {
  func testToolbarCenterpieceAppearsCentered() throws {
    let app = launch(mode: "empty")
    let metrics = try toolbarCenterpieceMetrics(in: app)

    let expectedLeadingInset: CGFloat = 12
    let leadingInsetTolerance: CGFloat = 1
    let expectedTrailingInset: CGFloat = 4
    let expectedStatusHorizontalInset: CGFloat = 12
    let statusInsetTolerance: CGFloat = 1
    let shouldCaptureDiagnostics =
      metrics.centerOffset > 120
      || metrics.verticalOffset > 8
      || abs(metrics.leadingInset - expectedLeadingInset) > leadingInsetTolerance
      || metrics.interiorGap < 20
      || abs(metrics.trailingInset - expectedTrailingInset) > leadingInsetTolerance
      || abs(metrics.statusLeadingInset - expectedStatusHorizontalInset) > statusInsetTolerance
      || abs(metrics.statusTrailingInset - expectedStatusHorizontalInset) > statusInsetTolerance
      || metrics.centerpieceFrame.width < 180

    if shouldCaptureDiagnostics {
      attachWindowScreenshot(in: app, named: "toolbar-centerpiece")
      let attachment = XCTAttachment(string: metrics.diagnostics)
      attachment.name = "toolbar-centerpiece-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertGreaterThanOrEqual(
      metrics.centerpieceFrame.width,
      180,
      "Expected the toolbar centerpiece to keep the stats visible in a compact capsule"
    )
    XCTAssertLessThanOrEqual(
      metrics.centerOffset,
      120,
      "Expected the toolbar centerpiece to stay near the window toolbar center"
    )
    XCTAssertLessThanOrEqual(
      metrics.verticalOffset,
      8,
      "Expected the toolbar centerpiece to stay vertically centered in the toolbar"
    )
    XCTAssertGreaterThanOrEqual(
      metrics.leadingInset,
      expectedLeadingInset - leadingInsetTolerance,
      "Expected the metrics row to keep the calculated leading inset inside the centerpiece capsule"
    )
    XCTAssertLessThanOrEqual(
      metrics.leadingInset,
      expectedLeadingInset + leadingInsetTolerance,
      "Expected the metrics row leading inset to match the capsule height-derived target"
    )
    XCTAssertGreaterThanOrEqual(
      metrics.interiorGap,
      20,
      "Expected the metrics row and status ticker to keep a visible interior gap"
    )
    XCTAssertGreaterThanOrEqual(
      metrics.trailingInset,
      expectedTrailingInset - leadingInsetTolerance,
      "Expected the status ticker host to sit flush to the trailing edge"
    )
    XCTAssertLessThanOrEqual(
      metrics.trailingInset,
      expectedTrailingInset + leadingInsetTolerance,
      "Expected the status ticker host trailing inset to stay near zero"
    )
    XCTAssertGreaterThanOrEqual(
      metrics.statusLeadingInset,
      expectedStatusHorizontalInset - statusInsetTolerance,
      "Expected the status hover capsule to keep the calculated leading inset"
    )
    XCTAssertLessThanOrEqual(
      metrics.statusLeadingInset,
      expectedStatusHorizontalInset + statusInsetTolerance,
      "Expected the status ticker leading inset to match the vertical inset"
    )
    XCTAssertGreaterThanOrEqual(
      metrics.statusTrailingInset,
      expectedStatusHorizontalInset - statusInsetTolerance,
      "Expected the status ticker to keep the calculated trailing inset"
    )
    XCTAssertLessThanOrEqual(
      metrics.statusTrailingInset,
      expectedStatusHorizontalInset + statusInsetTolerance,
      "Expected the status ticker trailing inset to match the vertical inset"
    )
  }

  func testToolbarCenterpieceNarrowsWhenInspectorIsVisible() throws {
    let app = launch(mode: "empty")
    let centerpieceFrame = frameElement(in: app, identifier: Accessibility.toolbarCenterpieceFrame)
    let inspectorToggleButton = toolbarButton(
      in: app, identifier: Accessibility.inspectorToggleButton)

    XCTAssertTrue(centerpieceFrame.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorToggleButton.waitForExistence(timeout: Self.actionTimeout))

    let widthWithInspector = centerpieceFrame.frame.width
    inspectorToggleButton.tap()

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        abs(centerpieceFrame.frame.width - widthWithInspector) >= 40
      }
    )

    let widthWithoutInspector = centerpieceFrame.frame.width
    XCTAssertGreaterThan(
      widthWithoutInspector,
      widthWithInspector + 40,
      "Expected the toolbar centerpiece to widen once the inspector is hidden"
    )
  }

  func testToolbarCenterpieceReportsPreviewMetrics() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let centerpiece = element(in: app, identifier: Accessibility.toolbarCenterpiece)
    let centerpieceState = element(in: app, identifier: Accessibility.toolbarCenterpieceState)

    XCTAssertTrue(centerpiece.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(centerpieceState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(centerpiece.label, "Harness Monitor, My Mac")
    XCTAssertEqual(centerpieceState.label, "projects=1, sessions=1, openWork=2, blocked=1")
  }

  func testToolbarCenterpieceUsesOnlySessionBackedProjectsAndWorktrees() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "toolbar-count-regression"]
    )
    let centerpieceState = element(in: app, identifier: Accessibility.toolbarCenterpieceState)
    let sidebarState = element(in: app, identifier: Accessibility.sidebarSessionListState)

    XCTAssertTrue(centerpieceState.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(sidebarState.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertEqual(sidebarState.label, "projects=2, worktrees=2, sessions=3")
    XCTAssertEqual(
      centerpieceState.label,
      "projects=2, worktrees=2, sessions=3, openWork=4, blocked=1"
    )
  }

  func testToolbarCenterpieceCompactsInsteadOfDisappearingInNarrowWindow() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard",
        "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "1180",
      ])
    let window = mainWindow(in: app)
    let toolbar = window.toolbars.firstMatch
    let centerpiece = element(in: app, identifier: Accessibility.toolbarCenterpiece)
    let centerpieceState = element(in: app, identifier: Accessibility.toolbarCenterpieceState)
    let centerpieceMode = element(in: app, identifier: Accessibility.toolbarCenterpieceMode)
    let toolbarChromeState = element(in: app, identifier: Accessibility.toolbarChromeState)
    let backButtons = app.toolbars.buttons.matching(identifier: Accessibility.navigateBackButton)
    let forwardButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.navigateForwardButton)
    let titlePredicate = NSPredicate(format: "label == %@ OR value == %@", "Dashboard", "Dashboard")
    let title = app.staticTexts.matching(titlePredicate).firstMatch
    let titleButtons = app.toolbars.buttons.matching(titlePredicate)

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    let observeButton = app.buttons.matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(backButtons.firstMatch.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.toolbarButton(in: app, identifier: Accessibility.navigateBackButton).isEnabled
      }, "Back button should be enabled after selecting a preview session")
    tapButton(in: app, identifier: Accessibility.navigateBackButton)
    XCTAssertTrue(forwardButtons.firstMatch.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.sessionsBoardRoot)
        .waitForExistence(timeout: Self.actionTimeout)
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.toolbarButton(in: app, identifier: Accessibility.navigateForwardButton).isEnabled
      }, "Forward button should be enabled after navigating back to the dashboard")
    let didCompact = waitUntil(timeout: Self.actionTimeout) {
      guard title.exists, centerpiece.exists else {
        return false
      }

      let centerpieceGap = centerpiece.frame.minX - title.frame.maxX

      return centerpiece.frame.width > 140
        && centerpieceState.exists
        && centerpieceMode.exists
        && toolbarChromeState.exists
        && toolbarChromeState.label.contains("toolbarTitle=native-window")
        && centerpieceMode.label == "compressed"
        && titleButtons.allElementsBoundByIndex.isEmpty
        && centerpieceGap >= 8
    }

    if !didCompact {
      attachWindowScreenshot(in: app, named: "toolbar-centerpiece-compact")
      attachAppHierarchy(in: app, named: "toolbar-centerpiece-compact-hierarchy")

      let diagnostics = """
        window: \(window.frame)
        toolbar: \(toolbar.frame)
        centerpiece exists: \(centerpiece.exists)
        centerpiece frame: \(centerpiece.exists ? String(describing: centerpiece.frame) : "missing")
        centerpiece state: \(centerpieceState.exists ? centerpieceState.label : "missing")
        centerpiece mode: \(centerpieceMode.exists ? centerpieceMode.label : "missing")
        toolbar chrome: \(toolbarChromeState.exists ? toolbarChromeState.label : "missing")
        title frame: \(title.exists ? String(describing: title.frame) : "missing")
        title buttons: \(titleButtons.allElementsBoundByIndex.count)
        back frame: \(String(describing: outerToolbarFrame(for: backButtons)))
        forward frame: \(String(describing: outerToolbarFrame(for: forwardButtons)))
        """
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "toolbar-centerpiece-compact-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertTrue(didCompact, "Expected the narrow toolbar to keep the centerpiece visible")
    XCTAssertEqual(centerpieceState.label, "projects=1, sessions=1, openWork=2, blocked=1")
  }

  func testToolbarStatusTickerRendersInPreview() throws {
    let app = launch(mode: "empty")
    let ticker = frameElement(in: app, identifier: Accessibility.toolbarStatusTickerFrame)

    let tickerExists = ticker.waitForExistence(timeout: Self.actionTimeout)
    if !tickerExists {
      attachWindowScreenshot(in: app, named: "status-ticker-not-found")
      attachAppHierarchy(in: app, named: "status-ticker-not-found-hierarchy")
    }
    XCTAssertTrue(tickerExists, "Status ticker element not found")
    XCTAssertGreaterThan(ticker.frame.width, 0)
  }

  private func toolbarCenterpieceMetrics(
    in app: XCUIApplication
  ) throws -> ToolbarCenterpieceMetrics {
    let window = mainWindow(in: app)
    let toolbar = window.toolbars.firstMatch
    let centerpiece = element(in: app, identifier: Accessibility.toolbarCenterpiece)
    let centerpieceFrame = frameElement(in: app, identifier: Accessibility.toolbarCenterpieceFrame)
    let metricsFrame = frameElement(
      in: app, identifier: Accessibility.toolbarCenterpieceMetricsFrame)
    let statusTicker = frameElement(in: app, identifier: Accessibility.toolbarStatusTickerFrame)
    let statusTickerContent = frameElement(
      in: app,
      identifier: Accessibility.toolbarStatusTickerContentFrame
    )

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(centerpiece.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(centerpieceFrame.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(statusTicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(statusTickerContent.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(metricsFrame.waitForExistence(timeout: Self.actionTimeout))

    return ToolbarCenterpieceMetrics(
      toolbarFrame: toolbar.frame,
      centerpieceFrame: centerpieceFrame.frame,
      metricsFrame: metricsFrame.frame,
      statusTickerFrame: statusTicker.frame,
      statusTickerContentFrame: statusTickerContent.frame,
      centerOffset: abs(centerpieceFrame.frame.midX - toolbar.frame.midX),
      verticalOffset: abs(centerpieceFrame.frame.midY - toolbar.frame.midY),
      leadingInset: metricsFrame.frame.minX - centerpieceFrame.frame.minX,
      interiorGap: statusTicker.frame.minX - metricsFrame.frame.maxX,
      trailingInset: centerpieceFrame.frame.maxX - statusTicker.frame.maxX,
      statusLeadingInset: statusTickerContent.frame.minX - statusTicker.frame.minX,
      statusTrailingInset: statusTicker.frame.maxX - statusTickerContent.frame.maxX
    )
  }
}

extension HarnessMonitorToolbarCenterpieceUITests {
  fileprivate func outerToolbarFrame(for query: XCUIElementQuery) -> CGRect? {
    query.allElementsBoundByIndex
      .compactMap { element in
        guard element.exists else { return nil }
        let frame = element.frame
        guard frame.width >= 40, frame.height >= 40 else { return nil }
        return frame
      }
      .max { lhs, rhs in (lhs.width * lhs.height) < (rhs.width * rhs.height) }
  }
}
