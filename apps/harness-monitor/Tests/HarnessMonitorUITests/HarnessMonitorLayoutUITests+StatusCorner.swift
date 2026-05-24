import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension HarnessMonitorLayoutUITests {
  func testCockpitSessionStatusCornerFollowsContentScroll() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let statusCorner = element(in: app, identifier: Accessibility.sessionStatusCorner)
    let statusCornerFrame = frameElement(
      in: app, identifier: Accessibility.sessionStatusCornerFrame)
    let headerCardFrame = frameElement(
      in: app, identifier: Accessibility.sessionHeaderCardFrame)
    let contentRoot = frameElement(in: app, identifier: Accessibility.contentRootFrame)

    XCTAssertTrue(waitForElement(statusCorner, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(statusCornerFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(headerCardFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(contentRoot, timeout: Self.actionTimeout))

    let initialHeaderFrame = headerCardFrame.frame
    let initialFrame = statusCornerFrame.frame

    XCTAssertEqual(
      initialFrame.minX,
      contentRoot.frame.minX,
      accuracy: 4,
      "Status corner should start at the detail content leading edge"
    )
    XCTAssertEqual(
      initialFrame.minY,
      contentRoot.frame.minY,
      accuracy: 4,
      "Status corner should start at the detail content top edge"
    )
    XCTAssertGreaterThan(
      initialHeaderFrame.minY,
      initialFrame.minY + 20,
      "Cockpit header should sit below the status corner instead of underneath it"
    )
    XCTAssertLessThan(
      initialHeaderFrame.minY,
      initialFrame.minY + 40,
      "Cockpit header should stay close to the status corner instead of leaving a large empty gap"
    )
    XCTAssertTrue(
      statusCorner.label.contains("Session status"),
      "Status corner should carry session status accessibility label"
    )

    for _ in 0..<6 {
      dragUp(in: app, element: headerCardFrame, distanceRatio: 0.4)
      if headerCardFrame.frame.minY < initialHeaderFrame.minY - 40 {
        break
      }
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        let currentHeaderFrame = headerCardFrame.frame
        let currentStatusFrame = statusCornerFrame.frame
        return currentHeaderFrame.minY < initialHeaderFrame.minY - 40
          && currentStatusFrame.minY < initialFrame.minY - 40
      },
      "Status corner should scroll away with the cockpit content"
    )
  }
}
