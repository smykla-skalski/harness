import Foundation
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class WorkspaceDecisionSnapshotUITests:
  HarnessMonitorUITestCase,
  WorkspaceWindowUITestSupporting
{
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let criticalDecisionID = "ui-inspector-critical"
  private static let infoDecisionID = "ui-inspector-info"
  private static let snoozeDecisionID = "snooze-snapshot-seed"
  private static let snoozeActionID = "snooze-snapshot-action"
  private static let previewPermissionKey = "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"
  private static let acpDecisionID = "acp-permission:preview-acp-permission-1"

  // MARK: - Default decision snapshots

  func testCaptureWorkspaceDecisionDeskOverview() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [Self.uiTestsKey: "1"]
    )

    let observerSummary = element(in: app, identifier: Accessibility.observeSummaryButton)
    XCTAssertTrue(waitForElement(observerSummary, timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.observeSummaryButton)

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    XCTAssertTrue(
      waitForElement(workspaceWindow, timeout: Self.uiTimeout),
      "Workspace window should open after tapping the workspace toolbar button"
    )

    let observerPanel = element(in: app, identifier: Accessibility.decisionsObserverPanel)
    XCTAssertTrue(waitForElement(observerPanel, timeout: Self.actionTimeout))

    saveWindowSnapshot(workspaceWindow, named: "workspace-decision-desk-overview")
  }

  func testCaptureWorkspaceDecisionDetailWithInspector() throws {
    let app = launch(
      mode: "empty",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.decisionSeedEnvKey: makeDefaultDecisionsPayload(),
      ]
    )

    tapButton(in: app, identifier: Accessibility.workspaceToolbarButton)

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    XCTAssertTrue(waitForElement(workspaceWindow, timeout: Self.uiTimeout))

    let decisionRow = button(
      in: app,
      identifier: Accessibility.decisionRow(Self.criticalDecisionID)
    )
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.uiTimeout),
      "Seeded critical decision row should appear before the detail snapshot"
    )
    tapButton(in: app, identifier: Accessibility.decisionRow(Self.criticalDecisionID))

    let detail = element(in: app, identifier: Accessibility.decisionDetail)
    XCTAssertTrue(
      waitForElement(detail, timeout: Self.actionTimeout),
      "Decision detail should render after selecting the seeded decision"
    )

    let inspector = element(in: app, identifier: Accessibility.decisionInspector)
    if !waitForElement(inspector, timeout: Self.fastActionTimeout) {
      let inspectorToggle = button(
        in: app,
        identifier: Accessibility.decisionInspectorToggle
      )
      XCTAssertTrue(
        waitForElement(inspectorToggle, timeout: Self.actionTimeout),
        "Decision inspector toggle should exist when the inspector is hidden"
      )
      tapButton(in: app, identifier: Accessibility.decisionInspectorToggle)
    }
    XCTAssertTrue(
      waitForElement(inspector, timeout: Self.actionTimeout),
      "Decision inspector should be visible for the detail snapshot"
    )

    saveWindowSnapshot(workspaceWindow, named: "workspace-decision-detail-inspector")
  }

  // MARK: - ACP permission snapshot

  func testCaptureWorkspaceWindowForAcpPermissionPrompt() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.previewPermissionKey: "1",
      ]
    )
    openWorkspaceWindow(in: app)

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    XCTAssertTrue(
      waitForElement(workspaceWindow, timeout: Self.actionTimeout),
      "ACP permission prompts should route directly into the workspace window"
    )
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.decisionRow(Self.acpDecisionID)),
        timeout: Self.actionTimeout
      ),
      "ACP permission decision should be visible in the workspace window before snapshot capture"
    )
    XCTAssertFalse(
      element(in: app, identifier: Accessibility.acpPermissionModal).exists,
      "ACP permission flow should not show a separate modal surface"
    )

    saveWindowSnapshot(workspaceWindow, named: "workspace-decision-acp-permission-window")
  }

  // MARK: - Snooze dialog snapshot

  func testCaptureWorkspaceWindowWithSnoozeDialogSnapshot() throws {
    let app = launch(
      mode: "empty",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.decisionSeedEnvKey: makeSnoozeDecisionPayload(),
      ]
    )

    tapButton(in: app, identifier: Accessibility.workspaceToolbarButton)

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    XCTAssertTrue(
      waitForElement(workspaceWindow, timeout: Self.uiTimeout),
      "Workspace window should open after tapping workspace toolbar button"
    )

    tapButton(in: app, identifier: Accessibility.decisionRow(Self.snoozeDecisionID))

    let snoozeTrigger = button(
      in: app,
      identifier: Accessibility.decisionAction(Self.snoozeActionID)
    )
    XCTAssertTrue(waitForElement(snoozeTrigger, timeout: Self.actionTimeout))
    tapButton(in: app, identifier: Accessibility.decisionAction(Self.snoozeActionID))

    let oneHourOption = button(in: app, title: "1 hour")
    XCTAssertTrue(
      waitForElement(oneHourOption, timeout: Self.actionTimeout),
      "Snooze confirmation dialog should expose duration options"
    )

    saveWindowSnapshot(workspaceWindow, named: "workspace-decision-snooze-dialog")
  }

  // MARK: - Helpers

  private func saveWindowSnapshot(_ window: XCUIElement, named name: String) {
    guard window.exists else {
      XCTFail("Cannot capture preview snapshot for \(name): target window does not exist.")
      return
    }
    let screenshot = window.screenshot()
    let artifactsDirectory =
      diagnosticsArtifactsDirectory(for: Self.artifactsDirectoryKey)
      ?? URL(fileURLWithPath: "/tmp/harness-monitor-design-snapshots", isDirectory: true)
    let outputURL = artifactsDirectory.appendingPathComponent("\(name).png")
    do {
      try FileManager.default.createDirectory(
        at: artifactsDirectory,
        withIntermediateDirectories: true
      )
      try screenshot.pngRepresentation.write(to: outputURL)
    } catch {
      XCTFail("Failed to save snapshot \(outputURL.path): \(error)")
    }
  }

  private func makeDefaultDecisionsPayload() -> String {
    let info: [String: Any] = [
      "id": Self.infoDecisionID,
      "severity": "info",
      "ruleID": "lint-debt",
      "summary": "Info decision for bulk-dismiss seed",
      "contextJSON": "{}",
      "suggestedActionsJSON": "[]",
    ]
    let critical: [String: Any] = [
      "id": Self.criticalDecisionID,
      "severity": "critical",
      "ruleID": "secret-exposed",
      "summary": "Critical decision for inspector metadata coverage",
      "contextJSON": "{\"snapshotExcerpt\":\"agent=agent-04 severity=critical\"}",
      "suggestedActionsJSON": "[]",
    ]
    return serializeJSONObject(["decisions": [critical, info]])
  }

  private func makeSnoozeDecisionPayload() -> String {
    let decision: [String: Any] = [
      "id": Self.snoozeDecisionID,
      "severity": "warn",
      "ruleID": "stuck-agent",
      "summary": "Snooze snapshot seed",
      "contextJSON": "{\"agentID\":\"agent-snapshot\"}",
      "suggestedActionsJSON": serializeJSONObject([
        [
          "id": Self.snoozeActionID,
          "title": "Snooze",
          "kind": "snooze",
          "payloadJSON": "{\"duration\":3600}",
        ]
      ]),
    ]
    return serializeJSONObject(["decisions": [decision]])
  }

  private func serializeJSONObject(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: []),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{\"decisions\":[]}"
    }
    return string
  }
}
