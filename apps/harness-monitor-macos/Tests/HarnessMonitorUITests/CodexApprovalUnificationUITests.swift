import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class CodexApprovalUnificationUITests: HarnessMonitorUITestCase {
  func testApprovalActionsExposeStableFrameMarkers() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_UI_TESTS": "1",
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "codex-approval-unification",
        "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS": makeDecisionSeed(),
      ]
    )

    reopenAgentTuiWindow(in: app)

    let acceptIdentifier = Accessibility.codexApprovalButton(
      "approval-preview-1",
      decision: "accept"
    )
    let acceptButton = button(in: app, identifier: acceptIdentifier)
    let acceptFrame = element(in: app, identifier: "\(acceptIdentifier).frame")

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        acceptButton.exists && acceptFrame.exists
      },
      "Codex approval actions must expose frame markers for deterministic UI taps"
    )
  }

  func testResolutionClearsAgentsAndDecisionsSurfaces() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_UI_TESTS": "1",
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "codex-approval-unification",
        "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS": makeDecisionSeed(),
      ]
    )

    reopenAgentTuiWindow(in: app)

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    let badgeState = element(in: app, identifier: Accessibility.supervisorBadgeState)
    let approveIdentifier = Accessibility.codexApprovalButton(
      "approval-preview-1",
      decision: "accept"
    )
    let approveButton = button(in: app, identifier: approveIdentifier)
    let approveElement = element(in: app, identifier: approveIdentifier)
    let approveFrame = element(in: app, identifier: "\(approveIdentifier).frame")

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        state.label.contains("selection=codex:preview-codex-approval-run")
          && state.label.contains("approvals=1")
          && approveButton.exists
          && self.markerText(for: badgeState).contains("severity=needsUser")
          && self.markerText(for: badgeState).contains("tint=orange")
      }
    )
    let initialBadgeCount = badgeCount(for: badgeState)

    tapButton(in: app, identifier: Accessibility.supervisorBadge)

    let decisionRow = button(
      in: app,
      identifier: Accessibility.decisionRow("codex-approval:sess1234:approval-preview-1")
    )
    XCTAssertTrue(waitForElement(decisionRow, timeout: Self.uiTimeout))
    tapButton(
      in: app,
      identifier: Accessibility.decisionRow("codex-approval:sess1234:approval-preview-1")
    )

    let decisionAcceptButton = button(in: app, identifier: Accessibility.decisionAction("accept"))
    XCTAssertTrue(waitForElement(decisionAcceptButton, timeout: Self.actionTimeout))
    tapButton(in: app, identifier: Accessibility.decisionAction("accept"))

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        !decisionRow.exists
      }
    )

    reopenAgentTuiWindow(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        state.label.contains("selection=codex:preview-codex-approval-run")
          && state.label.contains("approvals=0")
          && !approveButton.exists
          && !approveElement.exists
          && !approveFrame.exists
          && self.badgeCount(for: badgeState) < initialBadgeCount
      }
    )
  }

  private func reopenAgentTuiWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.agentsButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          || self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  private func tapDockButton(in app: XCUIApplication, identifier: String) {
    app.activate()
    let trigger = button(in: app, identifier: identifier)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        trigger.exists && !trigger.frame.isEmpty
      }
    )
    if trigger.isHittable {
      trigger.tap()
    } else if let coordinate = centerCoordinate(in: app, for: trigger) {
      coordinate.tap()
    } else {
      XCTFail("Cannot resolve coordinate for \(identifier)")
    }
  }

  private func makeDecisionSeed() -> String {
    let context = [
      "agentID": "preview-codex-approval-run",
      "approvalID": "approval-preview-1",
      "receivedAt": "2026-04-23T08:05:00Z",
      "snapshotID": "ui-test-codex-approval",
    ]
    let actions: [[String: Any]] = [
      action(
        id: "accept",
        title: "Accept",
        decision: "accept",
        mode: "accept"
      ),
      action(
        id: "accept_for_session",
        title: "Accept for session",
        decision: "accept_for_session",
        mode: "acceptForSession"
      ),
      action(
        id: "decline",
        title: "Decline",
        decision: "decline",
        mode: "decline"
      ),
      action(
        id: "cancel",
        title: "Cancel",
        decision: "cancel",
        mode: "cancel"
      ),
    ]
    return serializeJSONObject([
      "decisions": [
        [
          "id": "codex-approval:sess1234:approval-preview-1",
          "severity": "needsUser",
          "ruleID": "codex-approval",
          "sessionID": "sess1234",
          "agentID": "preview-codex-approval-run",
          "summary": "Approve workspace write",
          "contextJSON": serializeJSONObject(context),
          "suggestedActionsJSON": serializeJSONObject(actions),
        ]
      ]
    ])
  }

  private func action(
    id: String,
    title: String,
    decision: String,
    mode: String
  ) -> [String: Any] {
    [
      "id": id,
      "title": title,
      "kind": "custom",
      "payloadJSON": serializeJSONObject([
        "mode": mode,
        "agentID": "preview-codex-approval-run",
        "approvalID": "approval-preview-1",
        "decision": decision,
      ]),
    ]
  }

  private func serializeJSONObject(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: []),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  private func markerText(for element: XCUIElement) -> String {
    if !element.label.isEmpty {
      return element.label
    }
    if let value = element.value as? String, !value.isEmpty {
      return value
    }
    return element.debugDescription
  }

  private func badgeCount(for element: XCUIElement) -> Int {
    let marker = markerText(for: element)
    guard
      let countSegment = marker.split(separator: " ").first(where: { $0.hasPrefix("count=") })
    else {
      return -1
    }
    return Int(countSegment.dropFirst("count=".count)) ?? -1
  }
}
