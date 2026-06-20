import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class TaskBoardPolicyCanvasLiveDocumentStoreTests: XCTestCase {
  func testSupervisorOverridesUseLiveDocumentWhenActiveCanvasIsDraft() async throws {
    let client = RecordingHarnessClient()
    let draftDocument = client.sampleTaskBoardPolicyPipeline(
      canvasId: "canvas-active",
      title: "Draft Canvas",
      mode: .draft,
      revision: 4
    )
    let liveDocument = supervisorPolicyDocument(
      revision: 3,
      ruleID: "rule-live",
      decision: .deny
    )
    client.taskBoardPolicyPipelinesByCanvasID = [
      "canvas-active": draftDocument
    ]
    client.taskBoardPolicyAuditByCanvasID = [
      "canvas-active": client.sampleTaskBoardPolicyPipelineAudit(for: draftDocument)
    ]
    client.taskBoardPolicyCanvasWorkspaceStorage = TaskBoardPolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "canvas-active",
      canvases: [
        TaskBoardPolicyCanvasSummary(
          canvasId: "canvas-active",
          title: "Draft Canvas",
          revision: draftDocument.revision,
          mode: .draft,
          document: draftDocument,
          liveDocument: liveDocument,
          liveUpdatedAt: nil,
          nodeCount: draftDocument.nodes.count,
          edgeCount: draftDocument.edges.count,
          groupCount: draftDocument.groups.count,
          updatedAt: "2026-05-31T00:00:00Z"
        )
      ]
    )

    let store = await makeBootstrappedStore(client: client)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    await store.refreshTaskBoardPolicyPipeline()
    let overrides = try await liveDocumentOverrideState(for: store)

    XCTAssertEqual(overrides, ["rule-live": false])
  }
}

private func supervisorPolicyDocument(
  revision: UInt64,
  ruleID: String,
  decision: PolicyGraphDecision
) -> TaskBoardPolicyPipelineDocument {
  TaskBoardPolicyPipelineDocument(
    revision: revision,
    mode: .enforced,
    nodes: [
      TaskBoardPolicyPipelineNode(
        id: PolicyGraphNodeId(ruleID),
        title: "Supervisor \(ruleID)",
        kind: .supervisorRule(decision: decision, reasonCodes: [])
      )
    ],
    edges: [],
    groups: []
  )
}

@MainActor
private func liveDocumentOverrideState(
  for store: HarnessMonitorStore
) async throws -> [String: Bool] {
  let stack = try XCTUnwrap(store.supervisorStack)
  let overrides = await stack.registry.currentOverrides()
  return Dictionary(uniqueKeysWithValues: overrides.map { ($0.ruleID, $0.enabled) })
}
