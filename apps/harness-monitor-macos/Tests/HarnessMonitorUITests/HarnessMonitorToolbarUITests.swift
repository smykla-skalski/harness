import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorToolbarUITests: HarnessMonitorUITestCase {
  func testHiddenInspectorUsesSingleToolbarActionSet() throws {
    let app = launch(mode: "empty")
    let hideInspectorButton = button(in: app, title: "Hide Inspector")

    XCTAssertTrue(hideInspectorButton.waitForExistence(timeout: Self.uiTimeout))
    hideInspectorButton.tap()

    let showInspectorButtons = app.toolbars.buttons.matching(
      NSPredicate(format: "label == %@", "Show Inspector")
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
      NSPredicate(format: "label == %@", "Hide Inspector")
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

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(centerpiece.waitForExistence(timeout: Self.uiTimeout))

    let centerOffset = abs(centerpiece.frame.midX - toolbar.frame.midX)
    let verticalOffset = abs(centerpiece.frame.midY - toolbar.frame.midY)
    let diagnostics = """
      toolbar: \(toolbar.frame)
      centerpiece: \(centerpiece.frame)
      centerOffset: \(centerOffset)
      verticalOffset: \(verticalOffset)
      """

    if centerOffset > 90 || verticalOffset > 8 || centerpiece.frame.width < 180 {
      attachWindowScreenshot(in: app, named: "toolbar-centerpiece")
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "toolbar-centerpiece-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertGreaterThanOrEqual(
      centerpiece.frame.width,
      180,
      "Expected the toolbar centerpiece to keep the stats visible in a compact capsule"
    )
    XCTAssertLessThanOrEqual(
      centerOffset,
      90,
      "Expected the toolbar centerpiece to stay near the window toolbar center"
    )
    XCTAssertLessThanOrEqual(
      verticalOffset,
      8,
      "Expected the toolbar centerpiece to stay vertically centered in the toolbar"
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
