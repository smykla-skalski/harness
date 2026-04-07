import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

final class HarnessMonitorToolbarUITests: HarnessMonitorUITestCase {
  func testHiddenInspectorUsesSingleToolbarActionSet() throws {
    let app = launch(mode: "empty")
    let hideInspectorButton = toolbarButton(in: app, identifier: Accessibility.inspectorToggleButton)

    XCTAssertTrue(hideInspectorButton.waitForExistence(timeout: Self.uiTimeout))
    hideInspectorButton.tap()

    let showInspectorButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.inspectorToggleButton
    )
    let refreshButtons = app.toolbars.buttons.matching(identifier: Accessibility.refreshButton)
    let preferencesButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.preferencesButton
    )

    func distinctVisibleFrames(for query: XCUIElementQuery) -> Set<String> {
      Set(query.allElementsBoundByIndex.compactMap { element in
        guard element.exists else {
          return nil
        }
        let frame = element.frame
        // macOS toolbars expose an inner icon button inside the outer
        // toolbar control. We only want the outer control frame when
        // checking for duplicated visible buttons.
        guard frame.width >= 40, frame.height >= 40 else {
          return nil
        }
        return
          "\(Int(frame.minX.rounded())):"
          + "\(Int(frame.minY.rounded())):"
          + "\(Int(frame.width.rounded())):"
          + "\(Int(frame.height.rounded()))"
      })
    }

    let hasSingleToolbarSet = waitUntil(timeout: Self.uiTimeout) {
      (
        distinctVisibleFrames(for: refreshButtons).count == 1
          && distinctVisibleFrames(for: preferencesButtons).count == 1
          && distinctVisibleFrames(for: showInspectorButtons).count == 1
      )
    }

    if !hasSingleToolbarSet {
      attachWindowScreenshot(in: app, named: "hidden-inspector-toolbar")
      attachAppHierarchy(in: app, named: "hidden-inspector-toolbar-hierarchy")

      let diagnostics = """
        refresh: \(distinctVisibleFrames(for: refreshButtons).sorted())
        settings: \(distinctVisibleFrames(for: preferencesButtons).sorted())
        inspector: \(distinctVisibleFrames(for: showInspectorButtons).sorted())
        """
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "hidden-inspector-toolbar-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertTrue(
      hasSingleToolbarSet,
      "Expected exactly one visible refresh/settings/show-inspector control set"
    )
  }

  func testToolbarUsesNativeConciseWindowTitle() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let window = mainWindow(in: app)
    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)
    let toolbarChromeState = element(in: app, identifier: Accessibility.toolbarChromeState)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let detailTitle = app.staticTexts[Accessibility.previewSessionTitle]

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(toolbarChromeState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(detailTitle.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        toolbarChromeState.label.contains("windowTitle=Cockpit")
      },
      "Expected the preview scenario override to launch directly into cockpit state"
    )

    let toolbar = window.toolbars.firstMatch
    let longToolbarTitle = toolbar.staticTexts[Accessibility.previewSessionTitle]

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=button, controlGlass=native"
    )
    XCTAssertTrue(toolbarChromeState.label.contains("toolbarTitle=native-window"))
    XCTAssertTrue(toolbarChromeState.label.contains("windowTitle=Cockpit"))
    XCTAssertFalse(
      longToolbarTitle.exists,
      "Expected the long session context to stay in detail content, not the toolbar"
    )
    XCTAssertLessThanOrEqual(
      detailTitle.frame.maxX,
      inspectorRoot.frame.minX + 12,
      "Session context title should stay inside the detail column"
    )
  }

  func testToolbarCoversInspectorColumn() throws {
    let app = launch(mode: "empty")

    let window = mainWindow(in: app)
    let inspectorRoot = element(
      in: app,
      identifier: Accessibility.inspectorRoot
    )
    let inspectorCard = element(
      in: app,
      identifier: Accessibility.inspectorEmptyState
    )
    let refreshButton = toolbarButton(
      in: app,
      identifier: Accessibility.refreshButton
    )

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.uiTimeout))

    let toolbar = window.toolbars.firstMatch
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.uiTimeout))

    attachWindowScreenshot(in: app, named: "toolbar-inspector")

    let wFrame = window.frame
    let tFrame = toolbar.frame
    let iFrame = inspectorRoot.frame
    let rFrame = refreshButton.frame

    let diag = """
      window: \(wFrame)
      toolbar: \(tFrame)
      inspector: \(iFrame)
      refresh: \(rFrame)
      toolbar covers inspector X range: \(tFrame.maxX >= iFrame.maxX)
      inspector starts below toolbar: \(iFrame.minY >= tFrame.maxY - 4)
      """
    let attachment = XCTAttachment(string: diag)
    attachment.name = "frame-diagnostics"
    attachment.lifetime = .keepAlways
    add(attachment)

    // The toolbar background must visually cover the inspector column.
    // If toolbar.maxY <= inspector.minY, the inspector has no toolbar
    // above it and its background shows through unobstructed.
    //
    // In the correct layout, the toolbar frame should overlap with
    // the inspector's X range AND the inspector content should start
    // below the toolbar bottom.
    let inspectorTopOffset = iFrame.minY - wFrame.minY
    let toolbarBottomOffset = tFrame.maxY - wFrame.minY
    let toolbarOverlapsInspectorX = tFrame.maxX >= iFrame.minX

    XCTAssertTrue(
      toolbarOverlapsInspectorX,
      "Toolbar (maxX=\(tFrame.maxX)) does not reach inspector (minX=\(iFrame.minX))"
    )
    XCTAssertGreaterThanOrEqual(
      toolbarBottomOffset,
      inspectorTopOffset - 4,
      "Inspector (top=\(inspectorTopOffset)) starts above toolbar bottom "
        + "(\(toolbarBottomOffset)) - toolbar does not cover inspector region"
    )
  }

  func testInspectorToolbarActionsAnchorToTrailingEdge() throws {
    let app = launch(mode: "empty")
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let refreshButtons = app.toolbars.buttons.matching(identifier: Accessibility.refreshButton)
    let preferencesButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.preferencesButton
    )
    let hideInspectorButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.inspectorToggleButton
    )

    func outerToolbarFrame(for query: XCUIElementQuery) -> CGRect? {
      query.allElementsBoundByIndex
        .compactMap { element in
          guard element.exists else {
            return nil
          }
          let frame = element.frame
          guard frame.width >= 40, frame.height >= 40 else {
            return nil
          }
          return frame
        }
        .max { lhs, rhs in
          (lhs.width * lhs.height) < (rhs.width * rhs.height)
        }
    }

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))

    let isAnchoredTrailing = waitUntil(timeout: Self.uiTimeout) {
      guard
        let refreshFrame = outerToolbarFrame(for: refreshButtons),
        let preferencesFrame = outerToolbarFrame(for: preferencesButtons),
        let hideInspectorFrame = outerToolbarFrame(for: hideInspectorButtons)
      else {
        return false
      }

      let inspectorFrame = inspectorRoot.frame
      let groupLeading = min(refreshFrame.minX, preferencesFrame.minX, hideInspectorFrame.minX)
      let trailingGap = inspectorFrame.maxX - hideInspectorFrame.maxX

      return groupLeading >= inspectorFrame.midX - 24 && trailingGap <= 28
    }

    if !isAnchoredTrailing {
      attachWindowScreenshot(in: app, named: "inspector-toolbar-trailing-edge")

      let diagnostics = """
        inspector: \(inspectorRoot.frame)
        refresh: \(String(describing: outerToolbarFrame(for: refreshButtons)))
        settings: \(String(describing: outerToolbarFrame(for: preferencesButtons)))
        hide: \(String(describing: outerToolbarFrame(for: hideInspectorButtons)))
        """
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "inspector-toolbar-trailing-edge-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertTrue(
      isAnchoredTrailing,
      "Expected inspector toolbar actions to stay anchored to the inspector trailing edge"
    )
  }

  func testToolbarCenterpieceAppearsCentered() throws {
    let app = launch(mode: "empty")
    let window = mainWindow(in: app)
    let toolbar = window.toolbars.firstMatch
    let centerpiece = element(in: app, identifier: Accessibility.toolbarCenterpiece)
    let centerpieceFrame = frameElement(in: app, identifier: Accessibility.toolbarCenterpieceFrame)
    let metricsFrame = frameElement(in: app, identifier: Accessibility.toolbarCenterpieceMetricsFrame)
    let statusTicker = frameElement(in: app, identifier: Accessibility.toolbarStatusTickerFrame)
    let statusTickerContent = frameElement(
      in: app,
      identifier: Accessibility.toolbarStatusTickerContentFrame
    )
    let statusTickerHover = frameElement(
      in: app,
      identifier: Accessibility.toolbarStatusTickerHoverFrame
    )

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(centerpiece.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(centerpieceFrame.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(statusTicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(statusTickerContent.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(statusTickerHover.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(metricsFrame.waitForExistence(timeout: Self.uiTimeout))

    let centerOffset = abs(centerpieceFrame.frame.midX - toolbar.frame.midX)
    let verticalOffset = abs(centerpieceFrame.frame.midY - toolbar.frame.midY)
    let leadingInset = metricsFrame.frame.minX - centerpieceFrame.frame.minX
    let interiorGap = statusTicker.frame.minX - metricsFrame.frame.maxX
    let trailingInset = centerpieceFrame.frame.maxX - statusTicker.frame.maxX
    let statusLeadingInset = statusTickerContent.frame.minX - statusTicker.frame.minX
    let statusTrailingInset = statusTicker.frame.maxX - statusTickerContent.frame.maxX
    let hoverLeadingInset = statusTickerHover.frame.minX - statusTicker.frame.minX
    let hoverTrailingInset = statusTicker.frame.maxX - statusTickerHover.frame.maxX
    let hoverTopInset = statusTickerHover.frame.minY - statusTicker.frame.minY
    let hoverBottomInset = statusTicker.frame.maxY - statusTickerHover.frame.maxY
    let expectedLeadingInset: CGFloat = 12
    let leadingInsetTolerance: CGFloat = 1
    let expectedStatusHorizontalInset: CGFloat = 12
    let expectedHoverInset: CGFloat = 4
    let statusInsetTolerance: CGFloat = 1
    let diagnostics = """
      toolbar: \(toolbar.frame)
      centerpiece: \(centerpiece.frame)
      centerpieceFrame: \(centerpieceFrame.frame)
      metricsFrame: \(metricsFrame.frame)
      statusTicker: \(statusTicker.frame)
      statusTickerContent: \(statusTickerContent.frame)
      statusTickerHover: \(statusTickerHover.frame)
      centerOffset: \(centerOffset)
      verticalOffset: \(verticalOffset)
      leadingInset: \(leadingInset)
      interiorGap: \(interiorGap)
      trailingInset: \(trailingInset)
      statusLeadingInset: \(statusLeadingInset)
      statusTrailingInset: \(statusTrailingInset)
      hoverLeadingInset: \(hoverLeadingInset)
      hoverTrailingInset: \(hoverTrailingInset)
      hoverTopInset: \(hoverTopInset)
      hoverBottomInset: \(hoverBottomInset)
      """

    if centerOffset > 120
      || verticalOffset > 8
      || abs(leadingInset - expectedLeadingInset) > leadingInsetTolerance
      || interiorGap < 20
      || trailingInset < 10
      || abs(statusLeadingInset - expectedStatusHorizontalInset) > statusInsetTolerance
      || abs(statusTrailingInset - expectedStatusHorizontalInset) > statusInsetTolerance
      || abs(hoverLeadingInset - expectedHoverInset) > statusInsetTolerance
      || abs(hoverTrailingInset - expectedHoverInset) > statusInsetTolerance
      || abs(hoverTopInset - expectedHoverInset) > statusInsetTolerance
      || abs(hoverBottomInset - expectedHoverInset) > statusInsetTolerance
      || centerpieceFrame.frame.width < 180
    {
      attachWindowScreenshot(in: app, named: "toolbar-centerpiece")
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "toolbar-centerpiece-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertGreaterThanOrEqual(
      centerpieceFrame.frame.width,
      180,
      "Expected the toolbar centerpiece to keep the stats visible in a compact capsule"
    )
    XCTAssertLessThanOrEqual(
      centerOffset,
      120,
      "Expected the toolbar centerpiece to stay near the window toolbar center"
    )
    XCTAssertLessThanOrEqual(
      verticalOffset,
      8,
      "Expected the toolbar centerpiece to stay vertically centered in the toolbar"
    )
    XCTAssertGreaterThanOrEqual(
      leadingInset,
      expectedLeadingInset - leadingInsetTolerance,
      "Expected the metrics row to keep the calculated leading inset inside the centerpiece capsule"
    )
    XCTAssertLessThanOrEqual(
      leadingInset,
      expectedLeadingInset + leadingInsetTolerance,
      "Expected the metrics row leading inset to match the capsule height-derived target"
    )
    XCTAssertGreaterThanOrEqual(
      interiorGap,
      20,
      "Expected the metrics row and status ticker to keep a visible interior gap"
    )
    XCTAssertGreaterThanOrEqual(
      trailingInset,
      10,
      "Expected the status ticker to keep a trailing inset inside the centerpiece capsule"
    )
    XCTAssertGreaterThanOrEqual(
      statusLeadingInset,
      expectedStatusHorizontalInset - statusInsetTolerance,
      "Expected the status hover capsule to keep the calculated leading inset"
    )
    XCTAssertLessThanOrEqual(
      statusLeadingInset,
      expectedStatusHorizontalInset + statusInsetTolerance,
      "Expected the status hover capsule leading inset to match the vertical inset"
    )
    XCTAssertGreaterThanOrEqual(
      statusTrailingInset,
      expectedStatusHorizontalInset - statusInsetTolerance,
      "Expected the status hover capsule to keep the calculated trailing inset"
    )
    XCTAssertLessThanOrEqual(
      statusTrailingInset,
      expectedStatusHorizontalInset + statusInsetTolerance,
      "Expected the status hover capsule trailing inset to match the vertical inset"
    )
    XCTAssertGreaterThanOrEqual(
      hoverLeadingInset,
      expectedHoverInset - statusInsetTolerance,
      "Expected the hover plate leading inset to match the top/bottom inset"
    )
    XCTAssertLessThanOrEqual(
      hoverLeadingInset,
      expectedHoverInset + statusInsetTolerance,
      "Expected the hover plate leading inset to stay aligned with the top/bottom inset"
    )
    XCTAssertGreaterThanOrEqual(
      hoverTrailingInset,
      expectedHoverInset - statusInsetTolerance,
      "Expected the hover plate trailing inset to match the top/bottom inset"
    )
    XCTAssertLessThanOrEqual(
      hoverTrailingInset,
      expectedHoverInset + statusInsetTolerance,
      "Expected the hover plate trailing inset to stay aligned with the top/bottom inset"
    )
    XCTAssertGreaterThanOrEqual(
      hoverTopInset,
      expectedHoverInset - statusInsetTolerance,
      "Expected the hover plate top inset to stay at the calculated inset"
    )
    XCTAssertLessThanOrEqual(
      hoverTopInset,
      expectedHoverInset + statusInsetTolerance,
      "Expected the hover plate top inset to stay at the calculated inset"
    )
    XCTAssertGreaterThanOrEqual(
      hoverBottomInset,
      expectedHoverInset - statusInsetTolerance,
      "Expected the hover plate bottom inset to stay at the calculated inset"
    )
    XCTAssertLessThanOrEqual(
      hoverBottomInset,
      expectedHoverInset + statusInsetTolerance,
      "Expected the hover plate bottom inset to stay at the calculated inset"
    )
  }

  func testToolbarCenterpieceReportsPreviewMetrics() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let centerpiece = element(in: app, identifier: Accessibility.toolbarCenterpiece)
    let centerpieceState = element(in: app, identifier: Accessibility.toolbarCenterpieceState)

    XCTAssertTrue(centerpiece.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(centerpieceState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(centerpiece.label, "Harness Monitor, My Mac")
    XCTAssertEqual(centerpieceState.label, "projects=1, sessions=1, openWork=2, blocked=1")
  }

  func testToolbarCenterpieceCompactsInsteadOfDisappearingInNarrowWindow() throws {
    let app = launch(mode: "preview", additionalEnvironment: [
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
    let forwardButtons = app.toolbars.buttons.matching(identifier: Accessibility.navigateForwardButton)
    let titlePredicate = NSPredicate(format: "label == %@ OR value == %@", "Dashboard", "Dashboard")
    let title = app.staticTexts.matching(titlePredicate).firstMatch
    let titleButtons = app.toolbars.buttons.matching(titlePredicate)

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)
    let observeButton = app.buttons.matching(identifier: Accessibility.observeSummaryButton).firstMatch
    XCTAssertTrue(observeButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(backButtons.firstMatch.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(waitUntil(timeout: Self.uiTimeout) {
      self.toolbarButton(in: app, identifier: Accessibility.navigateBackButton).isEnabled
    }, "Back button should be enabled after selecting a preview session")
    tapButton(in: app, identifier: Accessibility.navigateBackButton)
    XCTAssertTrue(forwardButtons.firstMatch.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.sessionsBoardRoot)
        .waitForExistence(timeout: Self.uiTimeout)
    )
    XCTAssertTrue(waitUntil(timeout: Self.uiTimeout) {
      self.toolbarButton(in: app, identifier: Accessibility.navigateForwardButton).isEnabled
    }, "Forward button should be enabled after navigating back to the dashboard")
    let didCompact = waitUntil(timeout: Self.uiTimeout) {
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

      let centerpieceExists = centerpiece.exists
      let centerpieceFrameDescription = centerpieceExists ? String(describing: centerpiece.frame) : "missing"
      let centerpieceStateLabel = centerpieceState.exists ? centerpieceState.label : "missing"
      let centerpieceModeLabel = centerpieceMode.exists ? centerpieceMode.label : "missing"
      let toolbarChromeLabel = toolbarChromeState.exists ? toolbarChromeState.label : "missing"
      let titleDescription = title.exists ? String(describing: title.frame) : "missing"
      let backFrame = outerToolbarFrame(for: backButtons)
      let forwardFrame = outerToolbarFrame(for: forwardButtons)
      let titleButtonCount = titleButtons.allElementsBoundByIndex.count

      let diagnostics = """
        window: \(window.frame)
        toolbar: \(toolbar.frame)
        centerpiece exists: \(centerpieceExists)
        centerpiece frame: \(centerpieceFrameDescription)
        centerpiece state: \(centerpieceStateLabel)
        centerpiece mode: \(centerpieceModeLabel)
        toolbar chrome: \(toolbarChromeLabel)
        title frame: \(titleDescription)
        title buttons: \(titleButtonCount)
        back frame: \(String(describing: backFrame))
        forward frame: \(String(describing: forwardFrame))
        """
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "toolbar-centerpiece-compact-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertTrue(didCompact, "Expected the narrow toolbar to keep the centerpiece visible")
    XCTAssertEqual(centerpieceState.label, "projects=1, sessions=1, openWork=2, blocked=1")
  }

  func testToolbarStatusTickerShowsDropdownOnClick() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let ticker = element(in: app, identifier: Accessibility.toolbarStatusTicker)

    let tickerExists = ticker.waitForExistence(timeout: Self.uiTimeout)
    if !tickerExists {
      attachWindowScreenshot(in: app, named: "status-ticker-not-found")
      attachAppHierarchy(in: app, named: "status-ticker-not-found-hierarchy")
    }
    XCTAssertTrue(tickerExists, "Status ticker element not found")
    attachWindowScreenshot(in: app, named: "status-ticker-before-click")

    let window = mainWindow(in: app)
    guard window.waitForExistence(timeout: Self.uiTimeout) else {
      XCTFail("Window not found")
      return
    }
    let tickerFrame = ticker.frame
    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let toolbar = window.toolbars.firstMatch
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.uiTimeout))
    let tapY = tickerFrame.minY - window.frame.minY - 4
    let tapPoint = origin.withOffset(CGVector(
      dx: tickerFrame.midX - window.frame.minX,
      dy: tapY
    ))
    tapPoint.tap()

    let menuItem = app.menuItems["Running Harness Monitor"].firstMatch
    let menuAppeared = waitUntil(timeout: 3) { menuItem.exists }

    if !menuAppeared {
      attachWindowScreenshot(in: app, named: "status-ticker-after-click")
      attachAppHierarchy(in: app, named: "status-ticker-menu-hierarchy")

      let toolbar = window.toolbars.firstMatch
      let diagnostics = """
        ticker: \(tickerFrame)
        toolbar: \(toolbar.frame)
        window: \(window.frame)
        tapY offset from window: \(tickerFrame.minY - window.frame.minY - 6)
        """
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "status-ticker-tap-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertTrue(menuAppeared, "Expected the status ticker dropdown menu to appear on click")
  }
}

private extension HarnessMonitorToolbarUITests {
  func outerToolbarFrame(for query: XCUIElementQuery) -> CGRect? {
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
