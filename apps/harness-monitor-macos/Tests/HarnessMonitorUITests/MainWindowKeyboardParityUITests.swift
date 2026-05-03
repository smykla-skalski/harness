import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class MainWindowKeyboardParityUITests: HarnessMonitorUITestCase {
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
