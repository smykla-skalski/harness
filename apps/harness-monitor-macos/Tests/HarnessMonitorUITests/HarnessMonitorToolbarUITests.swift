import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

final class HarnessMonitorToolbarUITests: HarnessMonitorUITestCase {
  func testCockpitUsesSingleToolbarActionSet() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let refreshButtons = app.toolbars.buttons.matching(identifier: Accessibility.refreshButton)
    let inspectorButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.inspectorToggleButton
    )

    func distinctVisibleFrames(for query: XCUIElementQuery) -> Set<String> {
      Set(
        query.allElementsBoundByIndex.compactMap { element in
          guard element.exists else {
            return nil
          }
          let frame = element.frame
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

    let hasSingleToolbarSet = waitUntil(timeout: Self.actionTimeout) {
      distinctVisibleFrames(for: refreshButtons).count == 1
        && distinctVisibleFrames(for: inspectorButtons).count == 1
    }

    if !hasSingleToolbarSet {
      attachWindowScreenshot(in: app, named: "cockpit-toolbar-action-set")
      attachAppHierarchy(in: app, named: "cockpit-toolbar-action-set-hierarchy")
    }

    XCTAssertTrue(
      hasSingleToolbarSet,
      "Expected exactly one visible refresh/hide-inspector control set in cockpit state"
    )
  }

  func testHiddenInspectorUsesSingleToolbarActionSet() throws {
    let app = launch(mode: "empty")
    let hideInspectorButton = toolbarButton(
      in: app, identifier: Accessibility.inspectorToggleButton)

    XCTAssertTrue(hideInspectorButton.waitForExistence(timeout: Self.actionTimeout))
    hideInspectorButton.tap()

    let showInspectorButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.inspectorToggleButton
    )
    let refreshButtons = app.toolbars.buttons.matching(identifier: Accessibility.refreshButton)

    func distinctVisibleFrames(for query: XCUIElementQuery) -> Set<String> {
      Set(
        query.allElementsBoundByIndex.compactMap { element in
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

    let hasSingleToolbarSet = waitUntil(timeout: Self.actionTimeout) {
      (distinctVisibleFrames(for: refreshButtons).count == 1
        && distinctVisibleFrames(for: showInspectorButtons).count == 1)
    }

    if !hasSingleToolbarSet {
      attachWindowScreenshot(in: app, named: "hidden-inspector-toolbar")
      attachAppHierarchy(in: app, named: "hidden-inspector-toolbar-hierarchy")

      let diagnostics = """
        refresh: \(distinctVisibleFrames(for: refreshButtons).sorted())
        inspector: \(distinctVisibleFrames(for: showInspectorButtons).sorted())
        """
      let attachment = XCTAttachment(string: diagnostics)
      attachment.name = "hidden-inspector-toolbar-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertTrue(
      hasSingleToolbarSet,
      "Expected exactly one visible refresh/show-inspector control set"
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

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(toolbarChromeState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(detailTitle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        toolbarChromeState.label.contains("windowTitle=Cockpit")
      },
      "Expected the preview scenario override to launch directly into cockpit state"
    )

    let toolbar = window.toolbars.firstMatch
    let longToolbarTitle = toolbar.staticTexts[Accessibility.previewSessionTitle]

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=list, controlGlass=native"
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

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.actionTimeout))

    let toolbar = window.toolbars.firstMatch
    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))

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

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))

    let isAnchoredTrailing = waitUntil(timeout: Self.actionTimeout) {
      guard
        let refreshFrame = outerToolbarFrame(for: refreshButtons),
        let hideInspectorFrame = outerToolbarFrame(for: hideInspectorButtons)
      else {
        return false
      }

      let inspectorFrame = inspectorRoot.frame
      let groupLeading = min(refreshFrame.minX, hideInspectorFrame.minX)
      let trailingGap = inspectorFrame.maxX - hideInspectorFrame.maxX

      return groupLeading >= inspectorFrame.midX - 24 && trailingGap <= 28
    }

    if !isAnchoredTrailing {
      attachWindowScreenshot(in: app, named: "inspector-toolbar-trailing-edge")

      let diagnostics = """
        inspector: \(inspectorRoot.frame)
        refresh: \(String(describing: outerToolbarFrame(for: refreshButtons)))
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
}
