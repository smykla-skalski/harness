import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class AttentionInfrastructureUITests_UserNotification:
  HarnessMonitorUITestCase,
  AgentsWindowUITestSupporting
{
  private static let notificationAuthorizationKey =
    "HARNESS_MONITOR_PREVIEW_NOTIFICATION_AUTHORIZATION"
  private static let previewAttentionContextKey = "HARNESS_MONITOR_PREVIEW_ACP_ATTENTION_CONTEXT"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let previewAcpKey = "HARNESS_MONITOR_PREVIEW_ACP_PENDING"
  private static let previewBatchID = "preview-acp-permission-1"
  private static let decisionID = "acp-permission:\(previewBatchID)"
  private static let primaryActionID = "approve-selected"

  func testForegroundToastRoutesToFocusedDecisionAction() throws {
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
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let text = self.markerText(for: toastState)
        return text.contains("batch=\(Self.previewBatchID)")
          && text.contains("decision=\(Self.decisionID)")
      },
      "ACP toast state should publish the preview batch and ACP decision"
    )

    recordDiagnosticsTrace(
      event: "acp-toast.button-state",
      app: app,
      details: [
        "exists": String(openDecisionsButton.exists),
        "hittable": String(openDecisionsButton.isHittable),
      ]
    )
    tapButton(in: app, identifier: Accessibility.acpPermissionToastActionButton)

    let routeState = element(in: app, identifier: Accessibility.acpPermissionToastRouteState)
    let didPublishRoute = waitUntil(timeout: Self.actionTimeout) {
        let text = self.markerText(for: routeState)
        return text.contains("source=toast")
          && text.contains("decision=\(Self.decisionID)")
          && text.contains("batch=\(Self.previewBatchID)")
      }
    let buttonState = [
      "exists=\(openDecisionsButton.exists)",
      "hittable=\(openDecisionsButton.isHittable)",
      "enabled=\(openDecisionsButton.isEnabled)",
      "label=\(openDecisionsButton.label)",
      "value=\(String(describing: openDecisionsButton.value))",
    ].joined(separator: " ")
    XCTAssertTrue(
      didPublishRoute,
      """
      Toast tap should publish the ACP toast route marker
      button=\(buttonState)
      toast=\(markerText(for: toastState))
      route=\(markerText(for: routeState))
      """
    )
    recordDiagnosticsTrace(
      event: "acp-toast.route-state",
      app: app,
      details: ["value": markerText(for: routeState)]
    )

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
      "Toast route should mark the preview ACP decision row selected; actual=\(String(describing: decisionRow.value))"
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
}
