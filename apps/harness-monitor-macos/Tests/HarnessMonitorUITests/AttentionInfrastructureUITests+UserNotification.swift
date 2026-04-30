import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class AttentionInfrastructureUITestsUserNotification:
  HarnessMonitorUITestCase,
  AgentsWindowUITestSupporting
{
  private struct ForegroundToastContext {
    let app: XCUIApplication
    let openDecisionsButton: XCUIElement
    let toastState: XCUIElement
    let routeState: XCUIElement
    let preTapButtonState: String
  }

  private static let notificationAuthorizationKey =
    "HARNESS_MONITOR_PREVIEW_NOTIFICATION_AUTHORIZATION"
  private static let previewAttentionContextKey = "HARNESS_MONITOR_PREVIEW_ACP_ATTENTION_CONTEXT"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let previewAcpKey = "HARNESS_MONITOR_PREVIEW_ACP_PENDING"
  private static let previewBatchID = "preview-acp-permission-1"
  private static let decisionID = "acp-permission:\(previewBatchID)"
  private static let primaryActionID = "approve-selected"

  func testAcpPermissionToastPreviewSnapshot() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.previewAcpKey: "1",
        Self.previewAttentionContextKey: "foreground",
        Self.notificationAuthorizationKey: "authorized",
      ]
    )

    let openDecisionsButton = button(
      in: app,
      identifier: Accessibility.acpPermissionToastActionButton
    )
    XCTAssertTrue(
      waitForElement(openDecisionsButton, timeout: Self.uiTimeout),
      "Foreground ACP toast should expose an Open Decisions button before capture"
    )

    recordDiagnosticsSnapshot(in: app, named: "acp-permission-toast")
  }

  func testForegroundToastRoutesToFocusedDecisionAction() throws {
    let context = verifyForegroundToastSurfaceAndPrepareRoute()
    tapButton(in: context.app, identifier: Accessibility.acpPermissionToastActionButton)
    assertToastRoutePublished(context)
    assertToastRouteFocusesDecision(context.app)
  }

  func testSupervisorNotificationsPaneShowsDeniedAcpStatusAndSettingsLink() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.notificationAuthorizationKey: "denied",
      ]
    )

    openSettings(in: app)
    selectSupervisorNotificationsPane(in: app)

    let acpStatusState = element(
      in: app,
      identifier: Accessibility.preferencesAcpNotificationStatusState
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.markerText(for: acpStatusState).contains("authorization=denied")
      },
      "Supervisor Notifications preferences should publish the denied ACP authorization marker"
    )

    let settingsButton = button(
      in: app,
      identifier: Accessibility.preferencesAcpOpenSystemSettings
    )
    XCTAssertTrue(
      waitForElement(settingsButton, timeout: Self.actionTimeout),
      "Denied ACP notification state should expose Open System Settings"
    )
  }

  private func markerText(for element: XCUIElement) -> String {
    if let value = element.value {
      let rendered = String(describing: value)
      if rendered != "nil", !rendered.isEmpty {
        return rendered
      }
    }
    if let value = element.value as? String, !value.isEmpty {
      return value
    }
    if !element.label.isEmpty {
      return element.label
    }
    return element.debugDescription
  }

  private func verifyForegroundToastSurfaceAndPrepareRoute() -> ForegroundToastContext {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.previewAcpKey: "1",
        Self.previewAttentionContextKey: "foreground",
        Self.notificationAuthorizationKey: "authorized",
      ]
    )

    let openDecisionsButton = button(
      in: app,
      identifier: Accessibility.acpPermissionToastActionButton
    )
    XCTAssertTrue(
      waitForElement(openDecisionsButton, timeout: Self.uiTimeout),
      "Foreground ACP toast should expose an Open Decisions button"
    )

    let toastState = element(in: app, identifier: Accessibility.acpPermissionToastState)
    assertToastStateMarkers(toastState)
    assertToastAccessibilityContract(in: app)
    let preTapButtonState = assertToastGeometryAndSurfaceBlocking(
      in: app,
      openDecisionsButton: openDecisionsButton
    )
    let routeState = element(in: app, identifier: Accessibility.acpPermissionToastRouteState)
    return ForegroundToastContext(
      app: app,
      openDecisionsButton: openDecisionsButton,
      toastState: toastState,
      routeState: routeState,
      preTapButtonState: preTapButtonState
    )
  }

  private func assertToastStateMarkers(_ toastState: XCUIElement) {
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let text = self.markerText(for: toastState)
        return text.contains("batch=\(Self.previewBatchID)")
          && text.contains("decision=\(Self.decisionID)")
      },
      "ACP toast state should publish the preview batch and ACP decision"
    )
  }

  private func assertToastAccessibilityContract(in app: XCUIApplication) {
    let toastAccessibilityState = element(
      in: app,
      identifier: Accessibility.acpPermissionToastAccessibilityState
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let text = self.markerText(for: toastAccessibilityState)
        return text.contains("live-region=assertive")
          && text.contains("batch=\(Self.previewBatchID)")
      },
      "ACP toast should publish the assertive live-region accessibility contract"
    )
  }

  private func assertToastGeometryAndSurfaceBlocking(
    in app: XCUIApplication,
    openDecisionsButton: XCUIElement
  ) -> String {
    let toastFrameMarker = element(in: app, identifier: Accessibility.acpPermissionToastFrame)
    XCTAssertTrue(
      waitForElement(toastFrameMarker, timeout: Self.actionTimeout),
      "Foreground ACP toast should publish a frame marker for geometry diagnostics"
    )
    let actionFrameMarker = element(
      in: app,
      identifier: "\(Accessibility.acpPermissionToastActionButton).frame"
    )
    let closeButton = button(in: app, identifier: Accessibility.acpPermissionToastCloseButton)
    XCTAssertTrue(
      waitForElement(closeButton, timeout: Self.actionTimeout),
      "Foreground ACP toast should expose a dismiss button"
    )
    let preTapButtonState = renderToastButtonState(
      app: app,
      actionFrameMarker: actionFrameMarker,
      toastFrameMarker: toastFrameMarker,
      openDecisionsButton: openDecisionsButton
    )
    recordDiagnosticsTrace(
      event: "acp-toast.button-state",
      app: app,
      details: [
        "exists": String(openDecisionsButton.exists),
        "hittable": String(openDecisionsButton.isHittable),
        "buttonFrame": String(describing: openDecisionsButton.frame),
        "toastFrame": String(describing: toastFrameMarker.frame),
      ]
    )
    assertToastSurfaceBlocksHeaderActions(
      in: app,
      toastFrame: toastFrameMarker.frame,
      actionFrame: actionFrameMarker.frame,
      closeFrame: closeButton.frame
    )
    return preTapButtonState
  }

  private func assertToastRoutePublished(_ context: ForegroundToastContext) {
    let didPublishRoute = waitUntil(timeout: Self.actionTimeout) {
      let text = self.markerText(for: context.routeState)
      return text.contains("source=toast")
        && text.contains("decision=\(Self.decisionID)")
        && text.contains("batch=\(Self.previewBatchID)")
    }
    XCTAssertTrue(
      didPublishRoute,
      """
      Open Decisions button should publish the ACP toast route marker
      button=\(context.preTapButtonState)
      toast=\(markerText(for: context.toastState))
      route=\(markerText(for: context.routeState))
      """
    )
    recordDiagnosticsTrace(
      event: "acp-toast.route-state",
      app: context.app,
      details: ["value": markerText(for: context.routeState)]
    )
  }

  private func assertToastRouteFocusesDecision(_ app: XCUIApplication) {
    let decisionsWindow = element(in: app, identifier: Accessibility.decisionsWindow)
    XCTAssertTrue(
      waitForElement(decisionsWindow, timeout: Self.uiTimeout),
      "Toast route should open the Decisions window"
    )

    let decisionRow = button(in: app, identifier: Accessibility.decisionRow(Self.decisionID))
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.actionTimeout),
      "Toast route should select the preview ACP decision row"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (decisionRow.value as? String) == "selected"
      },
      """
      Toast route should mark the preview ACP decision row selected; \
      actual=\(String(describing: decisionRow.value))
      """
    )

    let focusState = element(in: app, identifier: Accessibility.decisionPrimaryActionFocusState)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let text = self.markerText(for: focusState)
        return text.contains("decision=\(Self.decisionID)") && text.contains("focused=true")
      },
      "Toast route should focus the decision's primary action"
    )

    let primaryAction = button(
      in: app,
      identifier: Accessibility.decisionAction(Self.primaryActionID)
    )
    XCTAssertTrue(waitForElement(primaryAction, timeout: Self.actionTimeout))
  }

  private func renderToastButtonState(
    app: XCUIApplication,
    actionFrameMarker: XCUIElement,
    toastFrameMarker: XCUIElement,
    openDecisionsButton: XCUIElement
  ) -> String {
    [
      "exists=\(openDecisionsButton.exists)",
      "hittable=\(openDecisionsButton.isHittable)",
      "enabled=\(openDecisionsButton.isEnabled)",
      "label=\(openDecisionsButton.label)",
      "value=\(String(describing: openDecisionsButton.value))",
      "buttonFrame=\(openDecisionsButton.frame)",
      "actionFrame=\(actionFrameMarker.frame)",
      "toastFrame=\(toastFrameMarker.frame)",
      "windowFrame=\(mainWindow(in: app).frame)",
    ].joined(separator: " ")
  }

  private func assertToastSurfaceBlocksHeaderActions(
    in app: XCUIApplication,
    toastFrame: CGRect,
    actionFrame: CGRect,
    closeFrame: CGRect
  ) {
    let endSessionButton = button(in: app, identifier: Accessibility.endSessionButton)
    XCTAssertTrue(
      waitForElement(endSessionButton, timeout: Self.actionTimeout),
      "Preview should expose an End Session header action behind the ACP toast"
    )

    let coveredFrame = toastFrame.intersection(endSessionButton.frame)
    XCTAssertFalse(
      coveredFrame.isNull || coveredFrame.isEmpty,
      """
      ACP toast should overlap the End Session header action for surface-blocking coverage
      toast=\(toastFrame)
      endSession=\(endSessionButton.frame)
      """
    )

    let protectedActionFrame = actionFrame.insetBy(dx: -6, dy: -6)
    let protectedCloseFrame = closeFrame.insetBy(dx: -6, dy: -6)
    let candidatePoints = [
      CGPoint(x: coveredFrame.minX + 4, y: coveredFrame.midY),
      CGPoint(x: coveredFrame.midX, y: coveredFrame.midY),
      CGPoint(x: coveredFrame.maxX - 4, y: coveredFrame.midY),
      CGPoint(x: coveredFrame.midX, y: coveredFrame.minY + 4),
      CGPoint(x: coveredFrame.midX, y: coveredFrame.maxY - 4),
    ]
    guard
      let targetPoint = candidatePoints.first(where: { point in
        !protectedActionFrame.contains(point) && !protectedCloseFrame.contains(point)
      })
    else {
      XCTFail(
        """
        Could not find a covered End Session point outside visible toast controls
        covered=\(coveredFrame)
        action=\(actionFrame)
        close=\(closeFrame)
        """
      )
      return
    }

    let window = mainWindow(in: app)
    let coordinate = window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(
        dx: targetPoint.x - window.frame.minX,
        dy: targetPoint.y - window.frame.minY
      )
    )
    coordinate.click()

    let endNowButton = button(in: app, title: "End Session Now")
    XCTAssertFalse(
      endNowButton.waitForExistence(timeout: Self.fastActionTimeout),
      "Clicking the visible ACP toast surface must not activate the header action behind it"
    )
  }
}
