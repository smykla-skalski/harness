import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PolicyCanvasStoreTests: XCTestCase {
  func testRefreshLoadsActiveCanvasWorkspaceSnapshot() async throws {
    let client = RecordingHarnessClient()
    _ = try await client.createPolicyCanvas(
      request: PolicyCanvasCreateRequest(title: "Release Policies")
    )
    let expectedWorkspace = try await client.policyCanvasWorkspace()

    let store = await makeBootstrappedStore(client: client)
    await store.refreshPolicyPipeline()

    XCTAssertEqual(store.contentUI.dashboard.policyCanvasWorkspace, expectedWorkspace)
    XCTAssertEqual(
      store.contentUI.dashboard.policyPipeline?.nodes.first?.title, "Release Policies")
    XCTAssertGreaterThanOrEqual(client.readCallCount(.policyCanvasWorkspace), 2)
  }

  func testRefreshKeepsExistingCanvasWorkspaceWhenFallbackPipelineLoads() async throws {
    let client = RecordingHarnessClient()
    _ = try await client.createPolicyCanvas(
      request: PolicyCanvasCreateRequest(title: "Release Policies")
    )
    let expectedWorkspace = try await client.policyCanvasWorkspace()

    let store = await makeBootstrappedStore(client: client)
    await store.refreshPolicyPipeline()
    XCTAssertEqual(
      store.contentUI.dashboard.policyCanvasWorkspace,
      expectedWorkspace
    )

    client.policyCanvasWorkspaceError = NSError(
      domain: "PolicyCanvasStoreTests",
      code: 1
    )
    await store.refreshPolicyPipeline()

    XCTAssertEqual(
      store.contentUI.dashboard.policyCanvasWorkspace,
      expectedWorkspace
    )
    XCTAssertEqual(
      store.contentUI.dashboard.policyPipeline?.nodes.first?.title, "Release Policies")
  }

  func testCanvasMutationsReloadActiveSnapshotAndKeepGuards() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    await store.refreshPolicyPipeline()
    let originalCanvasID = try XCTUnwrap(
      store.contentUI.dashboard.policyCanvasWorkspace?.activeCanvasId
    )

    let created = await store.createPolicyCanvas(title: "Escalations")
    XCTAssertTrue(created)
    let createdCanvasID = try XCTUnwrap(
      store.contentUI.dashboard.policyCanvasWorkspace?.activeCanvasId
    )
    XCTAssertNotEqual(createdCanvasID, originalCanvasID)
    XCTAssertEqual(
      store.contentUI.dashboard.policyPipeline?.nodes.first?.title, "Escalations")

    var updatedDocument = try XCTUnwrap(store.contentUI.dashboard.policyPipeline)
    updatedDocument.revision += 1
    let saved = await store.savePolicyPipelineDraft(document: updatedDocument)
    XCTAssertNotNil(saved)
    XCTAssertEqual(
      client.recordedSavedPolicyCanvasIDs().last.flatMap { $0 }, createdCanvasID)

    let simulated = await store.simulatePolicyPipeline()
    XCTAssertTrue(simulated)
    XCTAssertEqual(
      client.recordedSimulatedPolicyCanvasIDs().last.flatMap { $0 }, createdCanvasID)

    let promoted = await store.promotePolicyPipeline(revision: updatedDocument.revision)
    XCTAssertTrue(promoted)
    XCTAssertEqual(
      client.recordedPromotedPolicyCanvasIDs().last.flatMap { $0 }, createdCanvasID)

    let reactivated = await store.activatePolicyCanvas(canvasId: originalCanvasID)
    XCTAssertTrue(reactivated)
    XCTAssertEqual(
      store.contentUI.dashboard.policyCanvasWorkspace?.activeCanvasId,
      originalCanvasID
    )
    XCTAssertEqual(
      store.contentUI.dashboard.policyPipeline?.nodes.first?.title, "Policy Canvas 1")
  }

  func testRefreshHydratesInactiveEnforcedCanvasDocuments() async throws {
    let client = RecordingHarnessClient()
    let activeDocument = client.samplePolicyPipeline(
      canvasId: "canvas-active",
      title: "Draft Canvas",
      mode: .draft,
      revision: 1
    )
    let enforcedDocument = client.samplePolicyPipeline(
      canvasId: "canvas-enforced",
      title: "Effective Canvas",
      mode: .enforced,
      revision: 2
    )
    client.policyPipelinesByCanvasID = [
      "canvas-active": activeDocument,
      "canvas-enforced": enforcedDocument,
    ]
    client.policyAuditByCanvasID = [
      "canvas-active": client.samplePolicyPipelineAudit(for: activeDocument),
      "canvas-enforced": client.samplePolicyPipelineAudit(for: enforcedDocument),
    ]
    client.policyCanvasWorkspaceStorage = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "canvas-active",
      canvases: [
        client.policyCanvasSummary(
          canvasId: "canvas-active",
          title: "Draft Canvas",
          document: activeDocument,
          latestSimulation: nil
        ),
        makePolicyCanvasSummary(
          .init(
            canvasId: "canvas-enforced",
            title: "Effective Canvas",
            revision: enforcedDocument.revision,
            mode: .enforced,
            document: nil,
            nodeCount: enforcedDocument.nodes.count,
            edgeCount: enforcedDocument.edges.count,
            groupCount: enforcedDocument.groups.count
          )
        ),
      ]
    )

    let store = await makeBootstrappedStore(client: client)
    await store.refreshPolicyPipeline()

    let workspace = try XCTUnwrap(store.contentUI.dashboard.policyCanvasWorkspace)
    let enforcedCanvas = try XCTUnwrap(
      workspace.canvases.first(where: { $0.canvasId == "canvas-enforced" })
    )
    XCTAssertEqual(enforcedCanvas.document, enforcedDocument)
    XCTAssertGreaterThanOrEqual(client.readCallCount(.policyPipeline), 2)
  }

  func testGlobalPolicyEnforcementSetDoesNotMutateCanvasModes() async throws {
    let client = RecordingHarnessClient()
    let activeDocument = client.samplePolicyPipeline(
      canvasId: "canvas-active",
      title: "Draft Canvas",
      mode: .draft,
      revision: 1
    )
    let enforcedDocument = client.samplePolicyPipeline(
      canvasId: "canvas-enforced",
      title: "Effective Canvas",
      mode: .enforced,
      revision: 2
    )
    let dryRunDocument = client.samplePolicyPipeline(
      canvasId: "canvas-dry-run",
      title: "Dry Run Canvas",
      mode: .dryRun,
      revision: 3
    )
    client.policyPipelinesByCanvasID = [
      "canvas-active": activeDocument,
      "canvas-enforced": enforcedDocument,
      "canvas-dry-run": dryRunDocument,
    ]
    client.policyAuditByCanvasID = [
      "canvas-active": client.samplePolicyPipelineAudit(for: activeDocument),
      "canvas-enforced": client.samplePolicyPipelineAudit(for: enforcedDocument),
      "canvas-dry-run": client.samplePolicyPipelineAudit(for: dryRunDocument),
    ]
    client.policyCanvasWorkspaceStorage = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "canvas-active",
      canvases: [
        client.policyCanvasSummary(
          canvasId: "canvas-active",
          title: "Draft Canvas",
          document: activeDocument,
          latestSimulation: nil
        ),
        client.policyCanvasSummary(
          canvasId: "canvas-enforced",
          title: "Effective Canvas",
          document: enforcedDocument,
          latestSimulation: nil
        ),
        client.policyCanvasSummary(
          canvasId: "canvas-dry-run",
          title: "Dry Run Canvas",
          document: dryRunDocument,
          latestSimulation: nil
        ),
      ]
    )

    let store = await makeBootstrappedStore(client: client)
    await store.refreshPolicyPipeline()
    let before = try XCTUnwrap(store.contentUI.dashboard.policyCanvasWorkspace)
    let beforePolicyState = PolicyCanvasWorkspaceState(workspace: before)

    store.toast.dismissAll()

    let disabledResult = await store.setPolicyCanvasGlobalEnforcement(enabled: false)
    XCTAssertTrue(disabledResult)
    let disabled = try XCTUnwrap(store.contentUI.dashboard.policyCanvasWorkspace)
    XCTAssertFalse(disabled.globalPolicyEnforcementEnabled)
    XCTAssertEqual(PolicyCanvasWorkspaceState(workspace: disabled), beforePolicyState)
    XCTAssertTrue(store.toast.activeFeedback.isEmpty)

    let restoredResult = await store.setPolicyCanvasGlobalEnforcement(enabled: true)
    XCTAssertTrue(restoredResult)
    let restored = try XCTUnwrap(store.contentUI.dashboard.policyCanvasWorkspace)
    XCTAssertTrue(restored.globalPolicyEnforcementEnabled)
    XCTAssertEqual(PolicyCanvasWorkspaceState(workspace: restored), beforePolicyState)
    XCTAssertTrue(store.toast.activeFeedback.isEmpty)
  }

  func testSupervisorOverridesStayMergedAcrossCanvasActivation() async throws {
    let client = RecordingHarnessClient()
    let draftDocument = client.samplePolicyPipeline(
      canvasId: "canvas-draft",
      title: "Draft Canvas",
      mode: .draft,
      revision: 1
    )
    let firstEffectiveDocument = makeSupervisorPolicyDocument(
      revision: 2,
      ruleID: "rule-one",
      decision: .deny
    )
    let secondEffectiveDocument = makeSupervisorPolicyDocument(
      revision: 3,
      ruleID: "rule-two",
      decision: .allow
    )
    client.policyPipelinesByCanvasID = [
      "canvas-draft": draftDocument,
      "canvas-effective-1": firstEffectiveDocument,
      "canvas-effective-2": secondEffectiveDocument,
    ]
    client.policyAuditByCanvasID = [
      "canvas-draft": client.samplePolicyPipelineAudit(for: draftDocument),
      "canvas-effective-1": client.samplePolicyPipelineAudit(for: firstEffectiveDocument),
      "canvas-effective-2": client.samplePolicyPipelineAudit(for: secondEffectiveDocument),
    ]
    client.policyCanvasWorkspaceStorage = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "canvas-draft",
      canvases: [
        client.policyCanvasSummary(
          canvasId: "canvas-draft",
          title: "Draft Canvas",
          document: draftDocument,
          latestSimulation: nil
        ),
        makePolicyCanvasSummary(
          .init(
            canvasId: "canvas-effective-1",
            title: "Effective One",
            revision: firstEffectiveDocument.revision,
            mode: .enforced,
            document: nil,
            nodeCount: firstEffectiveDocument.nodes.count,
            edgeCount: firstEffectiveDocument.edges.count,
            groupCount: firstEffectiveDocument.groups.count
          )
        ),
        makePolicyCanvasSummary(
          .init(
            canvasId: "canvas-effective-2",
            title: "Effective Two",
            revision: secondEffectiveDocument.revision,
            mode: .enforced,
            document: nil,
            nodeCount: secondEffectiveDocument.nodes.count,
            edgeCount: secondEffectiveDocument.edges.count,
            groupCount: secondEffectiveDocument.groups.count
          )
        ),
      ]
    )

    let store = await makeBootstrappedStore(client: client)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    await store.refreshPolicyPipeline()
    let initialOverrides = try await currentOverrideState(for: store)

    let activated = await store.activatePolicyCanvas(canvasId: "canvas-effective-2")
    XCTAssertTrue(activated)

    let activatedOverrides = try await currentOverrideState(for: store)
    XCTAssertEqual(initialOverrides, activatedOverrides)
    XCTAssertEqual(
      activatedOverrides,
      [
        "rule-one": false,
        "rule-two": true,
      ]
    )
  }

}

private struct PolicyCanvasWorkspaceState: Equatable {
  var activeCanvasId: String
  var canvases: [PolicyCanvasState]

  init(workspace: PolicyCanvasWorkspace) {
    self.activeCanvasId = workspace.activeCanvasId
    self.canvases = workspace.canvases.map(PolicyCanvasState.init(canvas:))
  }
}

private struct PolicyCanvasState: Equatable {
  var canvasId: String
  var revision: UInt64
  var mode: PolicyPipelineMode
  var document: PolicyPipelineDocument?
  var liveDocument: PolicyPipelineDocument?
  var liveUpdatedAt: String?

  init(canvas: PolicyCanvasSummary) {
    self.canvasId = canvas.canvasId
    self.revision = canvas.revision
    self.mode = canvas.mode
    self.document = canvas.document
    self.liveDocument = canvas.liveDocument
    self.liveUpdatedAt = canvas.liveUpdatedAt
  }
}

private struct PolicyCanvasSummaryInput {
  var canvasId: String
  var title: String
  var revision: UInt64
  var mode: PolicyPipelineMode
  var document: PolicyPipelineDocument?
  var liveDocument: PolicyPipelineDocument?
  var liveUpdatedAt: String?
  var nodeCount: Int
  var edgeCount: Int
  var groupCount: Int
}

private func makePolicyCanvasSummary(
  _ input: PolicyCanvasSummaryInput
) -> PolicyCanvasSummary {
  PolicyCanvasSummary(
    canvasId: input.canvasId,
    title: input.title,
    revision: input.revision,
    mode: input.mode,
    document: input.document,
    liveDocument: input.liveDocument,
    liveUpdatedAt: input.liveUpdatedAt,
    nodeCount: input.nodeCount,
    edgeCount: input.edgeCount,
    groupCount: input.groupCount,
    updatedAt: "2026-05-31T00:00:00Z"
  )
}

private func makeSupervisorPolicyDocument(
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
private func currentOverrideState(
  for store: HarnessMonitorStore
) async throws -> [String: Bool] {
  let stack = try XCTUnwrap(store.supervisorStack)
  let overrides = await stack.registry.currentOverrides()
  return Dictionary(uniqueKeysWithValues: overrides.map { ($0.ruleID, $0.enabled) })
}
