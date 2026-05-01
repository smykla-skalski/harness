import Foundation
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class WorkspaceDecisionSnoozeDialogSnapshotUITests: HarnessMonitorUITestCase {
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let decisionID = "snooze-snapshot-seed"
  private static let snoozeActionID = "snooze-snapshot-action"

  func testCaptureWorkspaceWindowWithSnoozeDialogSnapshot() throws {
    let app = launch(
      mode: "empty",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.decisionSeedEnvKey: makeSeededDecisionsPayload(),
      ]
    )

    tapButton(in: app, identifier: Accessibility.workspaceToolbarButton)

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    XCTAssertTrue(
      waitForElement(workspaceWindow, timeout: Self.uiTimeout),
      "Workspace window should open after tapping workspace toolbar button"
    )

    tapButton(in: app, identifier: Accessibility.decisionRow(Self.decisionID))

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

    saveWindowSnapshot(
      workspaceWindow,
      named: "workspace-decision-snooze-dialog"
    )
  }

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

  private func makeSeededDecisionsPayload() -> String {
    let decision: [String: Any] = [
      "id": Self.decisionID,
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
