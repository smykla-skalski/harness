import Foundation
import Testing

/// Policy canvas replay is a daemon-backed UI action, so it must leave the
/// main actor through the shared Monitor work queue.
@Suite("Policy canvas replay actions source contract")
struct PolicyCanvasReplayActionsSourceContractTests {
  @Test("Replay action routes daemon work through shared async queue")
  func replayActionUsesSharedAsyncWorkQueue() throws {
    let source = try policyCanvasSourceFile(named: "PolicyCanvasView+ReplayActions.swift")
    let expectedWorkItem =
      "HarnessMonitorAsyncWorkQueue.WorkItem(title: \"Replaying policy decisions\")"

    #expect(source.contains("HarnessMonitorAsyncWorkQueue.shared.submit"))
    #expect(source.contains(expectedWorkItem))
    #expect(!source.contains("Task { @MainActor in"))
  }

  private func policyCanvasSourceFile(named fileName: String) throws -> String {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let monitorRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
    let url =
      monitorRoot
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas")
      .appendingPathComponent(fileName)
    return try String(contentsOf: url, encoding: .utf8)
  }
}
