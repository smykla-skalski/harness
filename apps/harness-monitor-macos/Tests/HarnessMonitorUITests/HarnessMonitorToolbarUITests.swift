import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

final class HarnessMonitorToolbarUITests: HarnessMonitorUITestCase {
  private func distinctVisibleToolbarFrames(for query: XCUIElementQuery) -> Set<String> {
    var frames = Set<String>()
    let searchCount = min(query.count, 8)
    for index in 0..<searchCount {
      let element = query.element(boundBy: index)
      guard element.exists else {
        continue
      }
      let frame = element.frame
      // macOS toolbars expose inner icon buttons inside the outer
      // toolbar control. Only count the outer control frame.
      guard frame.width >= 40, frame.height >= 40 else {
        continue
      }
      frames.insert(
        "\(Int(frame.minX.rounded())):"
          + "\(Int(frame.minY.rounded())):"
          + "\(Int(frame.width.rounded())):"
          + "\(Int(frame.height.rounded()))"
      )
    }
    return frames
  }

  func testDashboardLandingUsesSingleNewSessionToolbarAction() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )
    let newSessionButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.sidebarNewSessionButton
    )

    let hasSingleToolbarAction = waitUntil(timeout: Self.actionTimeout) {
      self.distinctVisibleToolbarFrames(for: newSessionButtons).count == 1
    }

    if !hasSingleToolbarAction {
      attachWindowScreenshot(in: app, named: "dashboard-landing-new-session-toolbar")
      attachAppHierarchy(in: app, named: "dashboard-landing-new-session-toolbar-hierarchy")
    }

    XCTAssertTrue(
      hasSingleToolbarAction,
      "Expected exactly one visible New Session toolbar control on dashboard landing"
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

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(toolbarChromeState.waitForExistence(timeout: Self.actionTimeout))
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
  }
}
