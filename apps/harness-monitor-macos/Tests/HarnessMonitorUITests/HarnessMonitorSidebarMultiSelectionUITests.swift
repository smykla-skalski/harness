import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSidebarMultiSelectionUITests: HarnessMonitorUITestCase {
  func testCommandClickKeepsCockpitPinnedToCurrentSession() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let primaryHeaderTitle = cockpitTitle(in: app, text: "Harness Monitor Cockpit")
    let secondaryHeaderTitle = cockpitTitle(in: app, text: "Signal retention verification")

    XCTAssertTrue(waitForElement(primarySelection, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(primaryHeaderTitle, timeout: Self.fastActionTimeout))

    modifierClickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      modifierFlags: .command
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        primarySelection.exists && secondarySelection.exists
      },
      "Command-click should extend the sidebar selection"
    )
    XCTAssertTrue(primaryHeaderTitle.exists)
    XCTAssertFalse(
      secondaryHeaderTitle.exists,
      "Command-click while multi-selecting must not retarget the cockpit"
    )
  }

  func testShiftClickKeepsCockpitPinnedToCurrentSession() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let primaryHeaderTitle = cockpitTitle(in: app, text: "Harness Monitor Cockpit")
    let secondaryHeaderTitle = cockpitTitle(in: app, text: "Signal retention verification")

    XCTAssertTrue(waitForElement(primarySelection, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(primaryHeaderTitle, timeout: Self.fastActionTimeout))

    clickSession(
      in: app,
      identifier: Accessibility.previewSessionRow,
      allowAlreadySelected: true
    )

    modifierClickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      modifierFlags: .shift
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        primarySelection.exists && secondarySelection.exists
      },
      "Shift-click should extend the sidebar selection range"
    )
    XCTAssertTrue(primaryHeaderTitle.exists)
    XCTAssertFalse(
      secondaryHeaderTitle.exists,
      "Shift-click while multi-selecting must not retarget the cockpit"
    )
  }

  private func cockpitTitle(in app: XCUIApplication, text: String) -> XCUIElement {
    let cockpitScroll = element(in: app, identifier: Accessibility.sessionCockpitScrollView)
    return cockpitScroll.descendants(matching: .staticText)
      .matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
      .firstMatch
  }

  private func sessionSelectionFrame(
    in app: XCUIApplication,
    identifier: String
  ) -> XCUIElement {
    element(in: app, identifier: "\(identifier).selection.frame")
  }
}
