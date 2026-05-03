import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class MainWindowKeyboardParityUITests: HarnessMonitorUITestCase {
  func testOpeningCockpitKeepsSidebarArrowNavigationActive() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySessionRow = sessionTrigger(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySessionRow = sessionTrigger(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let cockpitScrollView = element(
      in: app,
      identifier: Accessibility.sessionCockpitScrollView
    )
    let headerFrame = frameElement(
      in: app,
      identifier: Accessibility.sessionHeaderCardFrame
    )

    XCTAssertTrue(waitForElement(primarySessionRow, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(secondarySessionRow, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(cockpitScrollView, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(headerFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(self.sessionRowIsSelected(primarySessionRow))

    tapSession(in: app, identifier: Accessibility.sessionRow("sess5678"))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.sessionRowIsSelected(secondarySessionRow)
      }
    )

    tapSession(in: app, identifier: Accessibility.previewSessionRow)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.sessionRowIsSelected(primarySessionRow)
      }
    )

    let initialHeaderY = headerFrame.frame.minY
    app.typeKey(.pageDown, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        headerFrame.frame.minY < initialHeaderY - 12
      },
      """
      Page Down should still scroll the cockpit after it opens from a sidebar click.
      initialY=\(initialHeaderY)
      currentY=\(headerFrame.frame.minY)
      """
    )

    app.typeKey(.downArrow, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.sessionRowIsSelected(secondarySessionRow)
      },
      """
      Opening the cockpit must not steal sidebar keyboard navigation.
      primary=\(String(describing: primarySessionRow.value))
      secondary=\(String(describing: secondarySessionRow.value))
      """
    )
  }

  func testSpaceKeyScrollsCockpit() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    let cockpitScrollView = element(
      in: app,
      identifier: Accessibility.sessionCockpitScrollView
    )
    let headerFrame = frameElement(
      in: app,
      identifier: Accessibility.sessionHeaderCardFrame
    )

    XCTAssertTrue(waitForElement(cockpitScrollView, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(headerFrame, timeout: Self.actionTimeout))

    let initialHeaderY = headerFrame.frame.minY
    app.typeKey(.space, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        headerFrame.frame.minY < initialHeaderY - 12
      },
      """
      Space should scroll the cockpit surface without clicking into the sidebar first.
      initialY=\(initialHeaderY)
      currentY=\(headerFrame.frame.minY)
      """
    )
  }

  func testShiftSpaceKeyScrollsCockpitUp() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    let cockpitScrollView = element(
      in: app,
      identifier: Accessibility.sessionCockpitScrollView
    )
    let headerFrame = frameElement(
      in: app,
      identifier: Accessibility.sessionHeaderCardFrame
    )

    XCTAssertTrue(waitForElement(cockpitScrollView, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(headerFrame, timeout: Self.actionTimeout))

    app.typeKey(.space, modifierFlags: [])
    let scrolledDownY = headerFrame.frame.minY
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        headerFrame.frame.minY < scrolledDownY + 12
      }
    )

    app.typeKey(.space, modifierFlags: .shift)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        headerFrame.frame.minY > scrolledDownY + 12
      },
      """
      Shift-Space should scroll the cockpit surface up.
      downY=\(scrolledDownY)
      currentY=\(headerFrame.frame.minY)
      """
    )
  }
}
