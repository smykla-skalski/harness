import XCTest

@testable import HarnessMonitorKit

@MainActor
final class TaskBoardPolicyCanvasStoreTests: XCTestCase {
  func testRefreshLoadsActiveCanvasWorkspaceSnapshot() async throws {
    let client = RecordingHarnessClient()
    _ = try await client.createTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasCreateRequest(title: "Release Policies")
    )
    let expectedWorkspace = try await client.taskBoardPolicyCanvasWorkspace()

    let store = await makeBootstrappedStore(client: client)
    await store.refreshTaskBoardPolicyPipeline()

    XCTAssertEqual(store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace, expectedWorkspace)
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyPipeline?.nodes.first?.title, "Release Policies")
    XCTAssertGreaterThanOrEqual(client.readCallCount(.taskBoardPolicyCanvasWorkspace), 2)
  }

  func testCanvasMutationsReloadActiveSnapshotAndKeepGuards() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    await store.refreshTaskBoardPolicyPipeline()
    let originalCanvasID = try XCTUnwrap(
      store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.activeCanvasId
    )

    let created = await store.createTaskBoardPolicyCanvas(title: "Escalations")
    XCTAssertTrue(created)
    let createdCanvasID = try XCTUnwrap(
      store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.activeCanvasId
    )
    XCTAssertNotEqual(createdCanvasID, originalCanvasID)
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyPipeline?.nodes.first?.title, "Escalations")

    var updatedDocument = try XCTUnwrap(store.contentUI.dashboard.taskBoardPolicyPipeline)
    updatedDocument.revision += 1
    let saved = await store.saveTaskBoardPolicyPipelineDraft(document: updatedDocument)
    XCTAssertNotNil(saved)
    XCTAssertEqual(
      client.recordedSavedTaskBoardPolicyCanvasIDs().last.flatMap { $0 }, createdCanvasID)

    let simulated = await store.simulateTaskBoardPolicyPipeline()
    XCTAssertTrue(simulated)
    XCTAssertEqual(
      client.recordedSimulatedTaskBoardPolicyCanvasIDs().last.flatMap { $0 }, createdCanvasID)

    let promoted = await store.promoteTaskBoardPolicyPipeline(revision: updatedDocument.revision)
    XCTAssertTrue(promoted)
    XCTAssertEqual(
      client.recordedPromotedTaskBoardPolicyCanvasIDs().last.flatMap { $0 }, createdCanvasID)

    let reactivated = await store.activateTaskBoardPolicyCanvas(canvasId: originalCanvasID)
    XCTAssertTrue(reactivated)
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.activeCanvasId,
      originalCanvasID
    )
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyPipeline?.nodes.first?.title, "Policy Canvas 1")
  }

  func testRefreshHydratesInactiveEnforcedCanvasDocuments() async throws {
    let client = RecordingHarnessClient()
    let activeDocument = client.sampleTaskBoardPolicyPipeline(
      canvasId: "canvas-active",
      title: "Draft Canvas",
      mode: .draft,
      revision: 1
    )
    let enforcedDocument = client.sampleTaskBoardPolicyPipeline(
      canvasId: "canvas-enforced",
      title: "Effective Canvas",
      mode: .enforced,
      revision: 2
    )
    client.taskBoardPolicyPipelinesByCanvasID = [
      "canvas-active": activeDocument,
      "canvas-enforced": enforcedDocument,
    ]
    client.taskBoardPolicyAuditByCanvasID = [
      "canvas-active": client.sampleTaskBoardPolicyPipelineAudit(for: activeDocument),
      "canvas-enforced": client.sampleTaskBoardPolicyPipelineAudit(for: enforcedDocument),
    ]
    client.taskBoardPolicyCanvasWorkspaceStorage = TaskBoardPolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "canvas-active",
      canvases: [
        client.taskBoardPolicyCanvasSummary(
          canvasId: "canvas-active",
          title: "Draft Canvas",
          document: activeDocument,
          latestSimulation: nil
        ),
        makeTaskBoardPolicyCanvasSummary(
          canvasId: "canvas-enforced",
          title: "Effective Canvas",
          revision: enforcedDocument.revision,
          mode: .enforced,
          document: nil,
          nodeCount: enforcedDocument.nodes.count,
          edgeCount: enforcedDocument.edges.count,
          groupCount: enforcedDocument.groups.count
        ),
      ]
    )

    let store = await makeBootstrappedStore(client: client)
    await store.refreshTaskBoardPolicyPipeline()

    let workspace = try XCTUnwrap(store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace)
    let enforcedCanvas = try XCTUnwrap(
      workspace.canvases.first(where: { $0.canvasId == "canvas-enforced" })
    )
    XCTAssertEqual(enforcedCanvas.document, enforcedDocument)
    XCTAssertGreaterThanOrEqual(client.readCallCount(.taskBoardPolicyPipeline), 2)
  }

  func testSupervisorOverridesStayMergedAcrossCanvasActivation() async throws {
    let client = RecordingHarnessClient()
    let draftDocument = client.sampleTaskBoardPolicyPipeline(
      canvasId: "canvas-draft",
      title: "Draft Canvas",
      mode: .draft,
      revision: 1
    )
    let firstEffectiveDocument = makeSupervisorPolicyDocument(
      revision: 2,
      ruleID: "rule-one",
      decision: "deny"
    )
    let secondEffectiveDocument = makeSupervisorPolicyDocument(
      revision: 3,
      ruleID: "rule-two",
      decision: "allow"
    )
    client.taskBoardPolicyPipelinesByCanvasID = [
      "canvas-draft": draftDocument,
      "canvas-effective-1": firstEffectiveDocument,
      "canvas-effective-2": secondEffectiveDocument,
    ]
    client.taskBoardPolicyAuditByCanvasID = [
      "canvas-draft": client.sampleTaskBoardPolicyPipelineAudit(for: draftDocument),
      "canvas-effective-1": client.sampleTaskBoardPolicyPipelineAudit(for: firstEffectiveDocument),
      "canvas-effective-2": client.sampleTaskBoardPolicyPipelineAudit(for: secondEffectiveDocument),
    ]
    client.taskBoardPolicyCanvasWorkspaceStorage = TaskBoardPolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "canvas-draft",
      canvases: [
        client.taskBoardPolicyCanvasSummary(
          canvasId: "canvas-draft",
          title: "Draft Canvas",
          document: draftDocument,
          latestSimulation: nil
        ),
        makeTaskBoardPolicyCanvasSummary(
          canvasId: "canvas-effective-1",
          title: "Effective One",
          revision: firstEffectiveDocument.revision,
          mode: .enforced,
          document: nil,
          nodeCount: firstEffectiveDocument.nodes.count,
          edgeCount: firstEffectiveDocument.edges.count,
          groupCount: firstEffectiveDocument.groups.count
        ),
        makeTaskBoardPolicyCanvasSummary(
          canvasId: "canvas-effective-2",
          title: "Effective Two",
          revision: secondEffectiveDocument.revision,
          mode: .enforced,
          document: nil,
          nodeCount: secondEffectiveDocument.nodes.count,
          edgeCount: secondEffectiveDocument.edges.count,
          groupCount: secondEffectiveDocument.groups.count
        ),
      ]
    )

    let store = await makeBootstrappedStore(client: client)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    await store.refreshTaskBoardPolicyPipeline()
    let initialOverrides = try await currentOverrideState(for: store)

    let activated = await store.activateTaskBoardPolicyCanvas(canvasId: "canvas-effective-2")
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

private func makeTaskBoardPolicyCanvasSummary(
  canvasId: String,
  title: String,
  revision: UInt64,
  mode: TaskBoardPolicyPipelineMode,
  document: TaskBoardPolicyPipelineDocument?,
  nodeCount: Int,
  edgeCount: Int,
  groupCount: Int
) -> TaskBoardPolicyCanvasSummary {
  TaskBoardPolicyCanvasSummary(
    canvasId: canvasId,
    title: title,
    revision: revision,
    mode: mode,
    document: document,
    nodeCount: nodeCount,
    edgeCount: edgeCount,
    groupCount: groupCount,
    updatedAt: "2026-05-31T00:00:00Z"
  )
}

private func makeSupervisorPolicyDocument(
  revision: UInt64,
  ruleID: String,
  decision: String
) -> TaskBoardPolicyPipelineDocument {
  TaskBoardPolicyPipelineDocument(
    revision: revision,
    mode: .enforced,
    nodes: [
      TaskBoardPolicyPipelineNode(
        id: "supervisor-\(ruleID)",
        title: "Supervisor \(ruleID)",
        kind: TaskBoardPolicyPipelineNodeKind(
          kind: "supervisor_rule",
          ruleId: ruleID,
          decision: decision
        )
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
