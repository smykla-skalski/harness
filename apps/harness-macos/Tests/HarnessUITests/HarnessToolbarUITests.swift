import XCTest

private typealias Accessibility = HarnessUITestAccessibility

@MainActor
final class HarnessToolbarUITests: HarnessUITestCase {
  func testToolbarKeepsSelectedSessionTitleInsideDetailToolbar() throws {
    let app = launch(mode: "preview")
    let sessionRow = previewSessionTrigger(in: app)
    let chromeState = element(in: app, identifier: Accessibility.appChromeState)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(chromeState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))

    tapPreviewSession(in: app)

    let toolbarTitle = element(in: app, identifier: Accessibility.toolbarTitle)
    XCTAssertTrue(toolbarTitle.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(chromeState.label.contains("toolbarTitle=detail-scoped"))
    XCTAssertLessThanOrEqual(
      toolbarTitle.frame.maxX,
      inspectorRoot.frame.minX + 12,
      "Toolbar title overlaps the inspector toolbar region"
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
