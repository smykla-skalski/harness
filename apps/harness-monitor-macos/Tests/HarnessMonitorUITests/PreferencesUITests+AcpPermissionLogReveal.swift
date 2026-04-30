import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class PreferencesUITestsAcpPermissionLogReveal:
  HarnessMonitorUITestCase,
  AgentsWindowUITestSupporting
{
  private enum PermissionLogRevealExpectation {
    case opensLog
    case reportsUnavailable
  }

  func testDiagnosticsPermissionLogRevealHandlesAvailableAndMissingPaths() throws {
    verifyPermissionLogReveal(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"],
      expectation: .opensLog
    )
    verifyPermissionLogReveal(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1",
        "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_LOG_PATH": "__missing__",
      ],
      expectation: .reportsUnavailable
    )
  }

  private func verifyPermissionLogReveal(
    additionalEnvironment: [String: String],
    expectation: PermissionLogRevealExpectation,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let app = launchInCockpitPreview(additionalEnvironment: additionalEnvironment)
    defer { terminateIfRunning(app) }

    openSettings(in: app)
    selectPreferencesSection(
      in: app,
      identifier: Accessibility.preferencesDiagnosticsSection,
      expectedTitle: "Diagnostics"
    )

    let revealButtonID = Accessibility.preferencesAcpPermissionLogRevealButton("sess1234")
    let revealButton = scrollDiagnosticsUntilRevealButtonIsVisible(
      in: app,
      identifier: revealButtonID
    )
    XCTAssertTrue(
      waitForElement(revealButton, timeout: Self.uiTimeout),
      "Diagnostics should surface a reveal-permission-log button for active ACP runs",
      file: file,
      line: line
    )
    clickVisibleButtonFrame(in: app, identifier: revealButtonID)

    assertPermissionLogRevealResult(
      in: app,
      expectation: expectation,
      file: file,
      line: line
    )
  }

  private func assertPermissionLogRevealResult(
    in app: XCUIApplication,
    expectation: PermissionLogRevealExpectation,
    file: StaticString,
    line: UInt
  ) {
    let inlineErrorID = Accessibility.preferencesAcpPermissionLogError("sess1234")

    switch expectation {
    case .opensLog:
      let statusMessage = "Reveal requested in Finder."
      let statusID = Accessibility.preferencesAcpPermissionLogRevealStatus("sess1234")
      let status = element(in: app, identifier: statusID)
      let statusProbe = element(in: app, identifier: "\(statusID).probe")
      XCTAssertTrue(
        waitUntil(timeout: Self.uiTimeout) {
          status.exists || statusProbe.exists
        },
        "Diagnostics should confirm a successful ACP permission-log reveal request",
        file: file,
        line: line
      )
      assertAccessibleFeedback(
        primary: status,
        probe: statusProbe,
        expectedText: statusMessage,
        file: file,
        line: line
      )
      assertPermissionLogUnavailableErrorIsAbsent(in: app, file: file, line: line)
    case .reportsUnavailable:
      let errorMessage = "ACP permission log for this run is unavailable."
      let inlineError = element(in: app, identifier: inlineErrorID)
      let inlineErrorProbe = element(in: app, identifier: "\(inlineErrorID).probe")
      XCTAssertTrue(
        waitUntil(timeout: Self.uiTimeout) {
          inlineError.exists || inlineErrorProbe.exists
        },
        "Diagnostics should show inline error when permission log path is missing",
        file: file,
        line: line
      )
      assertAccessibleFeedback(
        primary: inlineError,
        probe: inlineErrorProbe,
        expectedText: errorMessage,
        file: file,
        line: line
      )
    }
  }

  private func assertAccessibleFeedback(
    primary: XCUIElement,
    probe: XCUIElement,
    expectedText: String,
    file: StaticString,
    line: UInt
  ) {
    let primaryValue = primary.value as? String ?? ""
    let primaryText = "\(primary.label) \(primaryValue)"
    let probeText = "\(probe.label) \(probe.value as? String ?? "")"
    XCTAssertTrue(
      primaryText.localizedCaseInsensitiveContains(expectedText)
        || probeText.localizedCaseInsensitiveContains(expectedText),
      "Feedback should expose '\(expectedText)' through the accessibility surface",
      file: file,
      line: line
    )
  }

  private func assertPermissionLogUnavailableErrorIsAbsent(
    in app: XCUIApplication,
    file: StaticString,
    line: UInt
  ) {
    let inlineError = app.staticTexts["ACP permission log for this run is unavailable."]
    XCTAssertFalse(
      waitForElement(inlineError, timeout: Self.fastPollInterval),
      "Reveal action should stay on the successful path for seeded ACP preview logs",
      file: file,
      line: line
    )
  }

  private func scrollDiagnosticsUntilRevealButtonIsVisible(
    in app: XCUIApplication,
    identifier: String
  ) -> XCUIElement {
    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    XCTAssertTrue(
      waitForElement(preferencesRoot, timeout: Self.uiTimeout),
      "Preferences window should be open before scrolling Diagnostics"
    )

    let preferencesWindow = window(in: app, containing: preferencesRoot)
    var revealButton = button(in: app, identifier: identifier)
    XCTAssertTrue(
      waitForElement(revealButton, timeout: Self.uiTimeout),
      "Diagnostics should render the ACP permission-log reveal button"
    )
    let scrollTarget = diagnosticsDetailScrollTarget(
      in: preferencesWindow,
      alignedWith: revealButton
    )

    for _ in 0..<6 {
      revealButton = button(in: app, identifier: identifier)
      if revealButton.isHittable {
        return revealButton
      }
      scrollDiagnosticsDetailDown(scrollTarget)
      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTAssertTrue(
      revealButton.isHittable,
      "ACP permission-log reveal button should be visible before tapping; frame=\(revealButton.frame)"
    )
    return revealButton
  }

  private func diagnosticsDetailScrollTarget(
    in preferencesWindow: XCUIElement,
    alignedWith target: XCUIElement
  ) -> XCUIElement {
    let targetMidX = target.frame.midX

    let scrollViewQuery = preferencesWindow.descendants(matching: .scrollView)
    let scrollViews = scrollViewQuery.allElementsBoundByIndex
    let candidates = scrollViews.filter { candidate in
      candidate.exists
        && !candidate.frame.isEmpty
        && candidate.frame.minX <= targetMidX
        && targetMidX <= candidate.frame.maxX
    }

    let detailCandidates = candidates.filter { candidate in
      candidate.frame.midX > preferencesWindow.frame.midX
    }

    let preferredCandidates = detailCandidates.isEmpty ? candidates : detailCandidates
    return preferredCandidates.max { left, right in
      left.frame.width * left.frame.height < right.frame.width * right.frame.height
    } ?? preferencesWindow
  }

  private func scrollDiagnosticsDetailDown(_ scrollTarget: XCUIElement) {
    let scrollDistance = max(160, scrollTarget.frame.height * 0.32)
    scrollTarget.scroll(byDeltaX: 0, deltaY: -scrollDistance)
  }

  private func clickVisibleButtonFrame(
    in app: XCUIApplication,
    identifier: String
  ) {
    let frameMarker = element(in: app, identifier: "\(identifier).frame")
    XCTAssertTrue(
      waitForElement(frameMarker, timeout: Self.actionTimeout),
      "Button \(identifier) should publish a frame marker before coordinate click"
    )
    let containingWindow = window(in: app, containing: frameMarker)
    XCTAssertTrue(
      waitForElement(containingWindow, timeout: Self.actionTimeout),
      "Button \(identifier) frame marker should belong to a visible window"
    )
    let visibleFrame = containingWindow.frame.intersection(frameMarker.frame)
    guard !visibleFrame.isNull, !visibleFrame.isEmpty else {
      XCTFail(
        "Button \(identifier) frame marker should be visible before click; frame=\(frameMarker.frame)"
      )
      return
    }
    let clickFrame = visibleFrame.insetBy(
      dx: min(4, max(visibleFrame.width / 4, 0)),
      dy: min(4, max(visibleFrame.height / 4, 0))
    )
    let targetFrame = clickFrame.isEmpty ? visibleFrame : clickFrame
    let targetPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    let coordinate = containingWindow.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(
        dx: targetPoint.x - containingWindow.frame.minX,
        dy: targetPoint.y - containingWindow.frame.minY
      )
    )
    guard !targetPoint.x.isNaN, !targetPoint.y.isNaN else {
      XCTFail("Failed to resolve visible frame marker for \(identifier)")
      return
    }
    coordinate.click()
  }
}
