import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension HarnessMonitorUITests {
  func testCockpitPageKeysScrollMainContentWithoutSidebarClick() throws {
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
    app.typeKey(.pageDown, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        headerFrame.frame.minY < initialHeaderY - 12
      },
      """
      Page Down should scroll the cockpit surface without first moving focus into the sidebar.
      initialY=\(initialHeaderY)
      currentY=\(headerFrame.frame.minY)
      """
    )

    let scrolledHeaderY = headerFrame.frame.minY
    app.typeKey(.pageUp, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        headerFrame.frame.minY > scrolledHeaderY + 12
      },
      """
      Page Up should keep driving the cockpit surface after the initial scroll.
      downY=\(scrolledHeaderY)
      currentY=\(headerFrame.frame.minY)
      """
    )
  }
}
