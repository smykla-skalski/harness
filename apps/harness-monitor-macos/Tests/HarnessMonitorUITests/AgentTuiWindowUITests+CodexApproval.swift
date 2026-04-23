import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension AgentTuiWindowUITests {
  func testCodexApprovalResolutionClearsAgentsAndDecisionsSurfaces() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_UI_TESTS": "1",
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "codex-approval-unification",
        "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS": makeCodexApprovalDecisionSeed(),
      ]
    )

    reopenAgentTuiWindow(in: app)

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    let badgeState = element(in: app, identifier: Accessibility.supervisorBadgeState)
    let agentApproveButton = button(in: app, title: "Accept")

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        state.label.contains("selection=codex:preview-codex-approval-run")
          && state.label.contains("approvals=1")
          && agentApproveButton.exists
          && self.markerText(for: badgeState).contains("severity=needsUser")
          && self.markerText(for: badgeState).contains("tint=orange")
      },
      """
      Agents window should expose the decision-backed approval on first open.
      state='\(state.label)'
      badge='\(markerText(for: badgeState))'
      """
    )
    let initialBadgeCount = badgeCount(for: badgeState)

    tapButton(in: app, identifier: Accessibility.supervisorBadge)

    let decisionRow = button(
      in: app,
      identifier: Accessibility.decisionRow("codex-approval:sess1234:approval-preview-1")
    )
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.uiTimeout),
      "Decisions window should show the same pending Codex approval"
    )

    reopenAgentTuiWindow(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("approvals=1") && agentApproveButton.exists
      },
      "Reopening the Agents window should keep the shared approval visible"
    )

    tapButton(in: app, title: "Accept")

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        state.label.contains("approvals=0")
          && self.badgeCount(for: badgeState) == initialBadgeCount - 1
      },
      """
      Resolving in the Agents window should clear the shared approval state.
      state='\(state.label)'
      badge='\(markerText(for: badgeState))'
      """
    )

    tapButton(in: app, identifier: Accessibility.supervisorBadge)
    let decisionsWindow = app.windows["Decisions"]
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { decisionsWindow.exists },
      "Decisions window should reopen after the shared approval clears"
    )
    XCTAssertFalse(
      decisionRow.waitForExistence(timeout: 1),
      "Resolved Codex approval should disappear from the Decisions window as well"
    )
  }

  private func makeCodexApprovalDecisionSeed() -> String {
    let context = [
      "agentID": "preview-codex-approval-run",
      "approvalID": "approval-preview-1",
      "receivedAt": "2026-04-23T08:05:00Z",
      "snapshotID": "ui-test-codex-approval",
    ]
    let actions: [[String: Any]] = [
      [
        "id": "accept",
        "title": "Accept",
        "kind": "custom",
        "payloadJSON": serializeJSONObject([
          "mode": "accept",
          "agentID": "preview-codex-approval-run",
          "approvalID": "approval-preview-1",
          "decision": "accept",
        ]),
      ],
      [
        "id": "accept_for_session",
        "title": "Accept for session",
        "kind": "custom",
        "payloadJSON": serializeJSONObject([
          "mode": "acceptForSession",
          "agentID": "preview-codex-approval-run",
          "approvalID": "approval-preview-1",
          "decision": "accept_for_session",
        ]),
      ],
      [
        "id": "decline",
        "title": "Decline",
        "kind": "custom",
        "payloadJSON": serializeJSONObject([
          "mode": "decline",
          "agentID": "preview-codex-approval-run",
          "approvalID": "approval-preview-1",
          "decision": "decline",
        ]),
      ],
      [
        "id": "cancel",
        "title": "Cancel",
        "kind": "custom",
        "payloadJSON": serializeJSONObject([
          "mode": "cancel",
          "agentID": "preview-codex-approval-run",
          "approvalID": "approval-preview-1",
          "decision": "cancel",
        ]),
      ],
    ]
    let decision: [String: Any] = [
      "id": "codex-approval:sess1234:approval-preview-1",
      "severity": "needsUser",
      "ruleID": "codex-approval",
      "sessionID": "sess1234",
      "agentID": "preview-codex-approval-run",
      "summary": "Approve workspace write",
      "contextJSON": serializeJSONObject(context),
      "suggestedActionsJSON": serializeJSONObject(actions),
    ]
    return serializeJSONObject(["decisions": [decision]])
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
