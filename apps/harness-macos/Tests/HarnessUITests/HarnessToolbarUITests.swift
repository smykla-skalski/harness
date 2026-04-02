import XCTest

private typealias Accessibility = HarnessUITestAccessibility

@MainActor
final class HarnessToolbarUITests: HarnessUITestCase {
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

    func visibleCount(for query: XCUIElementQuery) -> Int {
      query.allElementsBoundByIndex.filter { element in
        element.exists && element.isHittable
      }.count
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        visibleCount(for: refreshButtons) == 1
          && visibleCount(for: preferencesButtons) == 1
          && visibleCount(for: showInspectorButtons) == 1
      },
      "Expected exactly one visible refresh/settings/show-inspector control set"
    )
  }

  func testToolbarUsesNativeConciseWindowTitle() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_PREVIEW_SCENARIO": "cockpit"]
    )
    let window = mainWindow(in: app)
    let chromeState = element(in: app, identifier: Accessibility.appChromeState)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let detailTitle = app.staticTexts[Accessibility.previewSessionTitle]

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(chromeState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(detailTitle.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        chromeState.label.contains("windowTitle=Cockpit")
      },
      "Expected the preview scenario override to launch directly into cockpit state"
    )

    let toolbar = window.toolbars.firstMatch
    let longToolbarTitle = toolbar.staticTexts[Accessibility.previewSessionTitle]

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(chromeState.label.contains("toolbarTitle=native-window"))
    XCTAssertTrue(chromeState.label.contains("windowTitle=Cockpit"))
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
}
