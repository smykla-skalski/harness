import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session window route request contracts")
struct SessionWindowRouteRequestContractTests {
  @Test("Session windows gate later route requests until initial load completes")
  func sessionWindowsGateLaterRouteRequestsUntilInitialLoadCompletes() throws {
    let windowView = try windowViewUnionSource()
    let presentation = try sourceFile(named: "SessionWindowView+Presentation.swift")

    #expect(presentation.contains("let routeTrigger = pendingRouteTrigger"))
    #expect(presentation.contains(".task(id: routeTrigger)"))
    #expect(presentation.contains("guard routeTrigger.didLoadSnapshot else { return }"))
    #expect(windowView.contains("consumePendingSessionRouteRequest(forSessionID: token.sessionID)"))
  }

  @Test("Create-agent selection resets the split width through the persisted commit path")
  func createAgentSelectionResetsTheSplitWidthThroughThePersistedCommitPath() throws {
    let windowView = try windowViewUnionSource()
    let columns = try sourceFile(named: "SessionWindowView+Columns.swift")
    let detailFocus = try sourceFile(named: "SessionWindowView+DetailFocus.swift")

    #expect(
      columns.contains("case .create(let draft) = stateCache.selection, draft.kind == .agent"))
    #expect(columns.contains("SessionWindowCreateAgentRuntimePane("))
    #expect(detailFocus.contains("embedsRuntimeConfiguration: focusMode"))
    #expect(
      windowView.contains(
        "commitContentColumnWidth(SessionContentDetailSplitLayout.defaultContentWidth)"))
  }

  private func windowViewUnionSource() throws -> String {
    try [
      "SessionWindowView.swift",
      "SessionWindowView+Observers.swift",
    ]
    .map { try sourceFile(named: $0) }
    .joined(separator: "\n")
  }

  private func sourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let sourceURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(name)

    return try String(
      contentsOf: sourceURL,
      encoding: .utf8
    )
  }
}
