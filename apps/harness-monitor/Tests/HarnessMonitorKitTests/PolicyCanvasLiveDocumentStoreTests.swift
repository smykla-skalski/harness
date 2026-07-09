import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PolicyCanvasLiveDocumentStoreTests: XCTestCase {
  func testSupervisorOverridesUseLiveDocumentWhenActiveCanvasIsDraft() async throws {
    let client = RecordingHarnessClient()
    let draftDocument = client.samplePolicyPipeline(
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
    client.policyPipelinesByCanvasID = [
      "canvas-active": draftDocument
    ]
    client.policyAuditByCanvasID = [
      "canvas-active": client.samplePolicyPipelineAudit(for: draftDocument)
    ]
    client.policyCanvasWorkspaceStorage = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "canvas-active",
      canvases: [
        PolicyCanvasSummary(
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

    await store.refreshPolicyPipeline()
    let overrides = try await liveDocumentOverrideState(for: store)

    XCTAssertEqual(overrides, ["rule-live": false])
  }
}

private func supervisorPolicyDocument(
  revision: UInt64,
  ruleID: String,
  decision: PolicyGraphDecision
) -> PolicyPipelineDocument {
  PolicyPipelineDocument(
    revision: revision,
    mode: .enforced,
    nodes: [
      PolicyPipelineNode(
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
