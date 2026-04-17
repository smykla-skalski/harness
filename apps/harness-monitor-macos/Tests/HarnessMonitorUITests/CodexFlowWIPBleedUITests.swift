import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class CodexFlowWIPBleedUITests: HarnessMonitorUITestCase {
  func testCodexFlowPlaceholderUsesMinimalChromeWithoutWIPBadge() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    tapPreviewSession(in: app)

    let codexFlowPlaceholder = element(in: app, identifier: Accessibility.codexFlowButton)
    let placeholderIcon = element(in: app, identifier: Accessibility.codexFlowPlaceholderIcon)
    let wipBadge = app.descendants(matching: .any)["harness.session.codex-flow.wip"]

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        codexFlowPlaceholder.exists
          && !codexFlowPlaceholder.frame.isEmpty
          && placeholderIcon.exists
      }
    )
    XCTAssertFalse(
      waitUntil(timeout: Self.fastActionTimeout) { wipBadge.exists },
      "WIP badge should not exist after moving Codex Flow to the minimal hammer placeholder"
    )

    let iconCenterY = placeholderIcon.frame.midY
    let cardMinY = codexFlowPlaceholder.frame.minY
    let cardMaxY = codexFlowPlaceholder.frame.maxY
    XCTAssertGreaterThanOrEqual(iconCenterY, cardMinY)
    XCTAssertLessThanOrEqual(iconCenterY, cardMaxY)
  }
}
